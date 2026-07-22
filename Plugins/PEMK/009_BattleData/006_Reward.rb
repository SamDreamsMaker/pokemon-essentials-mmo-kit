#===============================================================================
# PEMK :: Reward  (client side — M4 Layer D D4, wild-battle reward reporting)
#-------------------------------------------------------------------------------
# When a WILD battle ends, the client reports its outcome + the foes it fought so the
# server can open a per-account reward BUDGET window (how much EXP/money that battle
# could legitimately have produced). Subsequent money deltas (the :econ channel) and
# party level jumps (the :mon_party projection) are then checked against that window
# server-side — detection-only (Rare Candies etc. legitimately level mons outside
# battle, so nothing is ever rejected).
#
# The foes are captured as they're generated (PEMK::Encounter's pbGenerateWildPokemon
# alias calls note_foe), so we have each foe's personalID — which, for a server-minted
# (D2 `on`) encounter, IS the id the server issued, letting it match the battle to the
# mints it stashed. Fire-and-forget; no reply. Modes off/shadow/on adopted at login
# (shadow and on both just detect in D4; a hard gate is future work).
#===============================================================================
module PEMK
  module Reward
    @mode = :off
    @foes = []   # personalIDs of the current battle's wild foes

    module_function

    def reset
      @mode = :off
      @foes = []
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end

    def active?
      return false if @mode == :off
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # Called from the wild-generation seam for each foe as it's built.
    def note_foe(pkmn)
      return unless active?
      return if @foes.length >= 2   # engine never fields more than a double wild battle

      pid = (pkmn.personalID rescue nil)
      @foes << pid if pid.is_a?(Integer)
    rescue StandardError
      nil
    end

    def clear_foes
      @foes = []
    end

    # Report the just-ended wild battle (outcome 0-5 + foe pids). Drains the foe list.
    def on_end(outcome)
      foes = @foes
      @foes = []
      return unless active? && foes.any? && outcome.is_a?(Integer)

      PEMK.send_message(:type => :battle_end_report, :outcome => outcome,
                        :foes => foes.map { |p| { :pid => p } })
    rescue StandardError => e
      PEMK.log("reward: report error #{e.class}: #{e.message}")
    end
  end
end

# Wild battle end -> report. :on_end_battle fires for wild battles (PvP uses its own
# checkpoint path and never reaches here). on_end DRAINS the foe list, so foes noted at
# generation (before :on_start_battle) survive to here — do NOT clear on :on_start_battle
# (it fires AFTER generation and would wipe them before the report).
if defined?(EventHandlers)
  EventHandlers.add(:on_end_battle, :pemk_reward_battle_end,
                    proc { |outcome, _can_lose| (PEMK::Reward.on_end(outcome) rescue nil) })
end
