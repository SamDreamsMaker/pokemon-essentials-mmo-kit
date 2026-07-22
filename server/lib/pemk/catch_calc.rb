# frozen_string_literal: true

require "securerandom"

module PEMK
  # M4 Layer D D3: server-side Poké Ball capture adjudication. Ports the engine's
  # pbCaptureCalc (005_Battle_CatchAndStoreMixin.rb:206) so the SHAKE ROLLS — the thing
  # that decides success — happen on the server with a cryptographic RNG: every catch
  # verdict comes from a real server roll. (A cheat can still RE-REQUEST after a miss —
  # the mint isn't consumed on failure, mirroring vanilla re-throws — so odds are only
  # as strong as the retry telemetry watching them; attempt counting + ball consumption
  # harden this when catches gain server-side consequences. Critical captures and the
  # Master-Ball-only unconditional set assume this fork's gen-8 settings.)
  #
  # The engine formula, reproduced exactly:
  #   x = floor(((3a - 2b) * rate) / (3a))   a=totalhp b=current hp, min 1
  #   x *= 2.5 (SLEEP/FROZEN) or 1.5 (other status)      [before the floor]
  #   caught outright if x >= 255 or Master Ball
  #   y = floor(65536 / (255/x)^0.1875)
  #   critical: c = x*dex_mod/12 (int div); roll(256)<c -> ONE roll(65536)<y -> 4 else 0
  #   else: up to 4 sequential roll(65536)<y, stop at first fail; 4 shakes = caught
  #
  # WHAT THE SERVER TRUSTS vs OWNS:
  #   owns    — the species catch rate (battle_data), the wild mon's totalhp (computed
  #             from base stats + the D2 mint's HP IV + level; nature never affects HP),
  #             every RNG roll, and the BALL CAP (a claimed modified rate is clamped to
  #             the ball's best legitimate multiplier).
  #   bounded — current HP (clamped 1..server totalhp), status (whitelist), the claimed
  #             ball-modified rate (clamped to cap), dex-owned count (clamped) — a lying
  #             client can shade odds *within the vanilla envelope* but never beyond the
  #             best case an honest player could reach with that same ball. Exact HP/
  #             status verification needs battle re-sim (D8).
  class CatchCalc
    SHAKE_SPACE = 65_536
    CRIT_SPACE  = 256

    # Multiplier CAP per ball: the best multiplier that ball can legitimately reach
    # (context balls list their max — Timer maxed, Quick turn-1, ...; gen-8 values, this
    # fork's MECHANICS_GENERATION). The client sends the rate its local ball handlers
    # computed; we clamp it into [1, cap(base)]. An unknown ball caps at x1.
    BALL_CAPS = {
      "POKEBALL" => 1.0, "PREMIERBALL" => 1.0, "LUXURYBALL" => 1.0, "HEALBALL" => 1.0,
      "FRIENDBALL" => 1.0, "CHERISHBALL" => 1.0,
      "GREATBALL" => 1.5, "SAFARIBALL" => 1.5, "SPORTBALL" => 1.5,
      "ULTRABALL" => 2.0,
      "NETBALL" => 3.5, "DIVEBALL" => 3.5, "REPEATBALL" => 3.5,
      "DUSKBALL" => 3.0,   # gen8 NEW_POKE_BALL_CATCH_RATES: x3 (not x3.5)
      "TIMERBALL" => 4.0, "MOONBALL" => 4.0, "DREAMBALL" => 4.0, "FASTBALL" => 4.0,
      "NESTBALL" => 4.0,   # (41 - level)/10, level >= 1 -> max 4.0
      "QUICKBALL" => 5.0, "LUREBALL" => 5.0, "BEASTBALL" => 5.0,
      "LEVELBALL" => 8.0, "LOVEBALL" => 8.0
    }.freeze
    # Balls whose engine handler additionally clamps the MODIFIED rate to <= 255
    # ([catchRate, 255].min / clamp 1..255) — without this ceiling, a base-255 species
    # with a claimed x8 would hit the x>=255 auto-catch at FULL HP, beating the honest
    # envelope. Heavy Ball (additive, clamp 1..255) is handled in effective_rate.
    CEILING_255 = %w[LEVELBALL LOVEBALL FASTBALL LUREBALL MOONBALL].freeze
    UNCONDITIONAL = { "MASTERBALL" => true }.freeze

    STATUS_MULT = {
      "SLEEP" => 2.5, "FROZEN" => 2.5,
      "POISON" => 1.5, "BURN" => 1.5, "PARALYSIS" => 1.5, "TOXIC" => 1.5
    }.freeze

    def initialize(battle_data, rng: SecureRandom)
      @bd  = battle_data
      @rng = rng   # responds to random_number(n)
    end

    # The wild mon's exact max HP, server-computed: floor((2*base + iv) * level / 100)
    # + level + 10 (wild EVs are 0; nature never affects HP; base 1 = always 1).
    # -> Integer | nil (species unknown to the export).
    def total_hp(species_id, level, hp_iv)
      sp = @bd.species(species_id.to_s)
      return nil unless sp

      base = sp["base_stats"].is_a?(Hash) ? sp["base_stats"]["HP"] : nil
      return nil unless base.is_a?(Integer)
      return 1 if base == 1   # Shedinja rule

      iv = hp_iv.is_a?(Integer) ? hp_iv.clamp(0, 31) : 0
      (((2 * base) + iv) * level / 100) + level + 10
    end

    # Adjudicate one ball throw. All client-supplied inputs are clamped (see header).
    # -> { shakes: 0..4, caught: bool, critical: bool, total_hp: Integer } | nil
    #    (nil = species unknown -> unjudgeable, caller fail-opens)
    def adjudicate(species_id, level, hp_iv, ball, hp_current, status,
                   claimed_rate: nil, dex_owned: 0, charm: false)
      sp = @bd.species(species_id.to_s)
      return nil unless sp

      lvl = level.is_a?(Integer) ? level.clamp(1, 100) : 1
      a   = total_hp(species_id, lvl, hp_iv)
      return nil unless a

      base = sp["catch_rate"].is_a?(Integer) ? sp["catch_rate"] : 0
      ub   = Array(sp["flags"]).include?("UltraBeast")   # absent in older exports -> false
      rate = effective_rate(ball, base, claimed_rate, ultra_beast: ub)
      b    = hp_current.is_a?(Integer) ? hp_current.clamp(1, a) : a

      if UNCONDITIONAL[ball.to_s]
        return { shakes: 4, caught: true, critical: false, total_hp: a }
      end

      x = (((3 * a) - (2 * b)) * rate.to_f) / (3 * a)
      x *= STATUS_MULT.fetch(status.to_s, 1.0)
      x = x.floor
      x = 1 if x < 1
      return { shakes: 4, caught: true, critical: false, total_hp: a } if x >= 255

      y = (SHAKE_SPACE / ((255.0 / x)**0.1875)).floor

      # Critical capture (engine thresholds; dex count clamped, charm doubles).
      dex = dex_owned.is_a?(Integer) ? dex_owned.clamp(0, 2000) : 0
      mod = if    dex > 600 then 5
            elsif dex > 450 then 4
            elsif dex > 300 then 3
            elsif dex > 150 then 2
            elsif dex > 30  then 1
            else 0
            end
      mod *= 2 if charm == true
      c = x * mod / 12   # integer division, as in the engine
      if c.positive? && @rng.random_number(CRIT_SPACE) < c
        caught = @rng.random_number(SHAKE_SPACE) < y
        return { shakes: (caught ? 4 : 0), caught: caught, critical: true, total_hp: a }
      end

      shakes = 0
      4.times do |i|
        break if shakes < i

        shakes += 1 if @rng.random_number(SHAKE_SPACE) < y
      end
      { shakes: shakes, caught: shakes == 4, critical: false, total_hp: a }
    end

    private

    # The catch rate actually used: the client's locally-modified rate (exact vanilla for
    # an honest client; kept Numeric — the engine carries e.g. 67.5 as a Float) clamped
    # into [1, the ball's best legitimate rate]. Heavy Ball is additive (up to +30,
    # engine-clamped to 255); CEILING_255 balls clamp their modified rate to 255 as the
    # engine does; an Ultra Beast in a non-Beast ball is base/10; unknown balls cap at
    # the unmodified base.
    def effective_rate(ball, base, claimed, ultra_beast: false)
      b = ball.to_s
      cap =
        if ultra_beast && b != "BEASTBALL"
          [base / 10, 1].max                       # engine: catch_rate /= 10, no modifier
        elsif b == "HEAVYBALL"
          [base + 30, 255].min
        else
          c = (base * BALL_CAPS.fetch(b, 1.0)).round
          CEILING_255.include?(b) ? [c, 255].min : c
        end
      cap = 1 if cap < 1
      c = claimed.is_a?(Numeric) ? claimed : base
      c.clamp(1, cap)
    end
  end
end
