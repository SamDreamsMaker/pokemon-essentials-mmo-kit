#===============================================================================
# PEMK :: Catch  (client side — M4 Layer D D3, server-adjudicated Poké Ball captures)
#-------------------------------------------------------------------------------
# The capture verdict funnels through ONE engine seam: Battle#pbCaptureCalc, which
# returns the shake count (0..4, 4 = caught) and sets @criticalCapture. We alias it.
#
# Modes (adopted from the login snapshot):
#   off    — local rolls, no traffic.
#   shadow — local calc unchanged; the client fire-and-forget REPORTS its inputs +
#            local shake result so the server can validate its ported formula.
#   on     — the client sends the throw's inputs and ADOPTS the server's verdict
#            (shakes + critical): the SERVER rolls the shakes, bound to the D2
#            encounter mint it issued. Fail-open: deny / timeout / offline / any
#            fault falls back to the local roll — a ball throw must always resolve.
#
# The client reports the ball-modified catch rate its own handlers computed (exact
# vanilla for honest players — context balls like Quick/Timer need battle state only
# the client has); the server CLAMPS it to the ball's legitimate maximum, so lying
# about it can only reach the ball's best case, never beyond.
#===============================================================================
module PEMK
  module Catch
    @mode  = :off   # server-advertised enforcement mode
    @seq   = 0      # client-local request id
    @inbox = {}     # seq => reply hash (delete-on-read)

    module_function

    def reset
      @mode  = :off
      @seq   = 0
      @inbox = {}
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end

    def online?
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    def shadow?;    @mode == :shadow && online?; end
    def enforcing?; @mode == :on     && online?; end

    # The throw's inputs, as primitives. claimed_rate is the LOCALLY ball-modified rate
    # (the same handlers + the Ultra-Beast /10 rule the local calc would use, kept
    # Numeric — the engine carries floats like 67.5), which the server clamps to the
    # ball's legitimate cap. -> Hash | nil (a build fault -> caller stays local).
    # NOTE: only D2-minted encounters can be server-adjudicated — static/event wild
    # battles, roamers and scaling-level maps never mint, so their catches stay local.
    def build_payload(pkmn, battler, ball, battle)
      base = pkmn.species_data.catch_rate
      ub   = (pkmn.species_data.has_flag?("UltraBeast") rescue false)
      claimed =
        if ub && ball.to_s != "BEASTBALL"
          base / 10   # engine: catch_rate /= 10, no ball modifier (005_...CatchAndStoreMixin)
        else
          begin
            Battle::PokeBallEffects.modifyCatchRate(ball, base, battle, battler)
          rescue StandardError
            base
          end
        end
      {
        :species      => pkmn.species.to_s,
        :level        => pkmn.level,
        :ball         => ball.to_s,
        :hp_current   => battler.hp,
        :status       => battler.status.to_s,
        :claimed_rate => (claimed.is_a?(Numeric) ? claimed : base),
        :dex_owned    => (($player.pokedex.owned_count rescue 0) || 0),
        :charm        => (($bag && $bag.has?(:CATCHINGCHARM)) rescue false) == true
      }
    rescue StandardError => e
      PEMK.log("catch: payload error #{e.class}: #{e.message}")
      nil
    end

    # ON: ask the server for the throw's verdict. -> { :shakes =>, :critical => } | nil
    # (deny / timeout / fault -> caller rolls locally).
    def request_verdict(pkmn, battler, ball, battle)
      payload = build_payload(pkmn, battler, ball, battle)
      return nil unless payload

      @inbox.clear
      @seq += 1
      PEMK.send_message(payload.merge(:type => :catch_req, :seq => @seq))
      r = wait_for(@seq)
      return nil unless r && r[:type] == :catch_verdict && r[:shakes].is_a?(Integer)

      { :shakes => r[:shakes].clamp(0, 4), :critical => (r[:critical] == true) }
    end

    # SHADOW: fire-and-forget the local result for server-side formula validation.
    def report(pkmn, battler, ball, battle, shakes)
      payload = build_payload(pkmn, battler, ball, battle)
      return unless payload

      PEMK.send_message(payload.merge(:type => :catch_report, :shakes => shakes))
    end

    # Dispatch routes :catch_verdict / :catch_deny here (delete-on-read by seq).
    def on_reply(msg)
      s = msg && msg[:seq]
      @inbox[s] = msg if s.is_a?(Integer)
    end

    def take(seq)
      @inbox.delete(seq)
    end

    # Block until the reply or the deadline, pumping frames. Graphics.update drives the
    # SDK net pump in EVERY scene (battle included); pbUpdateSceneMap is overworld-only,
    # so it is deliberately NOT called here.
    def wait_for(seq)
      deadline = mono + Config::CATCH_VERDICT_TIMEOUT
      loop do
        r = take(seq)
        return r if r
        return nil if mono >= deadline

        c = PEMK.client
        return nil unless c && c.connected?

        Graphics.update
        Input.update
      end
    rescue StandardError => e
      PEMK.log("catch: wait error #{e.class}: #{e.message}")
      nil
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end

# Intercept the single capture-verdict seam. Only a NORMAL wild catch is adjudicated
# (an explicit catch_rate arg = Safari/special path -> stays local; trainer battles never
# reach the calc). Reopens Battle (never edits core scripts); guarded for headless load.
if defined?(Battle) && Battle.method_defined?(:pbCaptureCalc) &&
   !Battle.method_defined?(:pemk_orig_pbCaptureCalc)
  class Battle
    alias_method :pemk_orig_pbCaptureCalc, :pbCaptureCalc
    def pbCaptureCalc(pkmn, battler, catch_rate, ball)
      if catch_rate.nil? && wildBattle? && (PEMK::Catch.enforcing? rescue false)
        v = (PEMK::Catch.request_verdict(pkmn, battler, ball, self) rescue nil)
        if v
          @criticalCapture = v[:critical]
          return v[:shakes]
        end
        # deny / timeout / fault -> fall through to the local roll
      end
      shakes = pemk_orig_pbCaptureCalc(pkmn, battler, catch_rate, ball)
      if catch_rate.nil? && wildBattle? && (PEMK::Catch.shadow? rescue false)
        (PEMK::Catch.report(pkmn, battler, ball, self, shakes) rescue nil)
      end
      shakes
    end
  end
end
