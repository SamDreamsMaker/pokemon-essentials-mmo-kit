# frozen_string_literal: true

module PEMK
  # M4 Layer D D4: closed-form wild-battle reward ENVELOPES. No turn loop — just the
  # engine's own arithmetic evaluated at its maximum:
  #
  # EXP (gen-8 scaled formula, 003_Battle_ExpAndMoveLearning.rb): per defeated/caught
  # foe, each gainer gets  floor(floor(a/5) * levelAdjust) + 1  with a = foe_level *
  # base_exp and levelAdjust maximized at gainer level 1; then the maximal multiplier
  # stack — international-trade x1.7, Exp Charm x3/2, Lucky Egg x3/2 — applied with the
  # engine's own floor-at-each-step rounding (affection is disabled in this fork; gen 8
  # never splits between gainers). Party-wide: up to 6 gainers at the per-mon max.
  #
  # LEVELS -> EXP: being at level L means exp < curve(L+1), so jumping L -> N requires
  # AT LEAST curve(N) - curve(L+1) + 1 exp — a conservative lower bound computable from
  # the exported growth curves alone (the client never reports raw exp).
  #
  # MONEY (wild battles): gains come only from Pay Day (x2 Amulet Coin x2 Happy Hour at
  # payout) — per-use <= 5*100, turn count unbounded, so the envelope is a generous
  # per-battle constant; losses are capped by the engine at max_party_level * 120
  # (badge multiplier table tops at 120). Detection-only bounds, not exact accounting.
  class RewardCalc
    EXP_GAINERS_MAX      = 6      # a full party can all be participants at gen 8
    MONEY_LOSS_PER_LEVEL = 120    # blackout: maxPartyLevel * 120 (badge table tops at 120)
    MONEY_GAIN_PER_LEVEL = 1_000  # generous Pay Day ceiling (~50 max-level uses x2 Amulet x2 Happy Hour)

    def initialize(battle_data)
      @bd = battle_data
    end

    # Money envelopes derived from the EXPORTED max level (forks may raise MAXIMUM_LEVEL,
    # which lifts both the blackout loss and the Pay-Day-per-level ceiling).
    def max_level; (@bd.max_level.is_a?(Integer) ? @bd.max_level : 100); end
    def wild_money_loss_max; max_level * MONEY_LOSS_PER_LEVEL; end
    def wild_money_gain_max; max_level * MONEY_GAIN_PER_LEVEL; end

    # Max exp ONE party mon can gain from this foe (level-1 gainer, full multiplier
    # stack, engine rounding). -> Integer | nil (species unknown / no base_exp).
    def max_exp_per_mon(species_id, foe_level)
      sp = @bd.species(species_id.to_s)
      return nil unless sp

      base = sp["base_exp"]
      return nil unless base.is_a?(Integer) && base.positive?

      lvl = foe_level.is_a?(Integer) ? foe_level.clamp(1, 100) : 1
      a   = lvl * base
      exp = a / 5                                                   # integer division
      la  = Math.sqrt((((2 * lvl) + 10.0) / (1 + lvl + 10.0))**5)   # gainer level 1
      exp = (exp * la).floor + 1                                    # participant +1
      exp = (exp * 17) / 10                                         # x1.7 international
      exp = exp * 3 / 2                                             # Exp Charm
      exp * 3 / 2                                                   # Lucky Egg
    end

    # Party-wide exp envelope for one foe. -> Integer | nil.
    def max_exp_per_foe(species_id, foe_level)
      per = max_exp_per_mon(species_id, foe_level)
      per && per * EXP_GAINERS_MAX
    end

    # Conservative MINIMUM exp needed to jump old_level -> new_level on +rate+.
    # -> Integer | nil (unknown rate / no exported curve / bad levels -> unjudgeable).
    def min_exp_for_jump(rate, old_level, new_level)
      return nil unless old_level.is_a?(Integer) && new_level.is_a?(Integer)
      return 0 unless new_level > old_level

      target = @bd.exp_for_level(rate, new_level)
      ceil   = @bd.exp_for_level(rate, old_level + 1)
      return nil unless target && ceil

      [target - ceil + 1, 0].max
    end
  end
end
