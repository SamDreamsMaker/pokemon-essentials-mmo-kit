#===============================================================================
# PEMK :: BattleScenePump  (Phase 4c.1 — keep the network alive during battle)
#-------------------------------------------------------------------------------
# During a battle $scene is a Battle::Scene, NOT a Scene_Map, so the global
# pbUpdateSceneMap alias (which only pumps for Scene_Map) never fires and the
# network goes completely silent for the whole battle. Battle::Scene#pbUpdate is
# the single per-frame method every battle wait/menu/animation loop calls, so
# aliasing it (guarded, prepend-only, control flow untouched) keeps
# PEMK::Pump.tick running each frame throughout the battle. Pump.tick
# self-throttles per Graphics.frame_count and rescues its own errors, so the many
# per-frame call sites are safe and can never break the battle loop.
#===============================================================================
class Battle::Scene
  unless method_defined?(:pokemmo_orig_battle_pbUpdate)
    alias_method :pokemmo_orig_battle_pbUpdate, :pbUpdate
    def pbUpdate(cw = nil)
      pokemmo_orig_battle_pbUpdate(cw)
      PEMK::Pump.tick
      # 4c.6: stream the host's RNG every frame (not just per round) so the client
      # replays near-simultaneously instead of a whole turn behind. No-op on the
      # client and when there is nothing new to send.
      @battle.pokemmo_flush_rng if @battle.respond_to?(:pokemmo_flush_rng)
    end
  end
end
