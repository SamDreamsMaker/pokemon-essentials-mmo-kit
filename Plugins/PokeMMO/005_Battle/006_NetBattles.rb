#===============================================================================
# PokeMMO :: NetBattles  (Phase 4c.3 — role-based battle subclasses)
#-------------------------------------------------------------------------------
# The two battle classes for a networked PvP battle. The HOST runs the ONE
# authoritative battle; the CLIENT mirrors it. For 4c.3 these are plain Battle
# subclasses (pure scaffolding: role assignment + construction), behaving exactly
# like a normal Battle. Their real behaviour is added incrementally:
#   - 4c.4: HostBattle consumes the client's human choices (instead of AI) and
#           records; ClientBattle sends its choices up to the host.
#   - 4c.5: HostBattle streams the authoritative per-round packet (choices + RNG
#           + switches + decision); ClientBattle replays it deterministically.
#===============================================================================
module PokeMMO
  class HostBattle < Battle
  end

  class ClientBattle < Battle
  end
end
