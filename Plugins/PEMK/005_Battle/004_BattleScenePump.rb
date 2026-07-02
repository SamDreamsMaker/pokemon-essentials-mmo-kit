#===============================================================================
# PEMK :: BattleScenePump  (Phase 4c.1 / 4c.6 — per-frame RNG stream during battle)
#-------------------------------------------------------------------------------
# The network pump itself runs from the global Graphics.update alias (see Hooks),
# which fires inside Battle::Scene#pbGraphicsUpdate too, so the link stays alive
# during battles for free. What is still battle-specific is streaming the HOST's
# RNG every frame (4c.6): aliasing Battle::Scene#pbUpdate (the single per-frame
# battle method) lets the host flush its unsent RNG each frame so the client
# replays near-simultaneously instead of a whole turn behind. Prepend-only,
# control flow untouched; flush is a no-op on the client and when nothing is new.
#===============================================================================
class Battle::Scene
  unless method_defined?(:pokemmo_orig_battle_pbUpdate)
    alias_method :pokemmo_orig_battle_pbUpdate, :pbUpdate
    def pbUpdate(cw = nil)
      pokemmo_orig_battle_pbUpdate(cw)
      @battle.pokemmo_flush_rng if @battle.respond_to?(:pokemmo_flush_rng)
    end
  end
end
