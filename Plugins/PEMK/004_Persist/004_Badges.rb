#===============================================================================
# PEMK :: Badges  (client side, Phase 2c-light)
#-------------------------------------------------------------------------------
# Badges are an attr_accessor Array on Player, granted by `$player.badges[i] = true`
# (Array#[]=), so an aliased Player method can never intercept them. Instead we
# transparently swap @badges for a ServerBadges (an Array subclass) whose []=
# notifies the server on a real change; the server validates the index and acks,
# and the client applies the ack silently.
#
# ServerBadges round-trips through Marshal (the save) fine because Marshal fills
# the array in C, not via []=, so loading never spuriously notifies. Same trust
# caveat as the rest of Phase 2c (foundation, not full anti-cheat).
#===============================================================================
module PEMK
  class ServerBadges < Array
    attr_accessor :pokemmo_silent   # when true, []= applies without notifying

    def []=(index, value)
      old    = (index >= 0 && index < length) ? self[index] : nil
      result = super
      # OBSERVER -> Sync dirty-set (coalesced), rather than a socket write per set.
      PEMK::Sync.mark_badge(index, value ? true : false) if !@pokemmo_silent && old != value
      result
    end
  end
end

class Player
  alias_method :pokemmo_orig_badges, :badges unless method_defined?(:pokemmo_orig_badges)

  # Transparently upgrade @badges to a ServerBadges the first time it's read.
  def badges
    b = pokemmo_orig_badges
    return b if b.is_a?(PEMK::ServerBadges)
    sb = PEMK::ServerBadges.new
    sb.concat(b) if b.is_a?(Array)
    @badges = sb
    sb
  end

  # Trusted applier for server reconciliation (:badge_ack) — never re-notifies.
  def pokemmo_apply_badge(index, owned)
    b = badges
    b.pokemmo_silent = true
    b[index] = owned ? true : false
    b.pokemmo_silent = false
  end
end

# --- Backward compatibility with pre-rename saves --------------------------------
# Saves written before the PokeMMO -> PEMK rename stored $player.badges as a
# PokeMMO::ServerBadges. Alias the old constant so Marshal.load of those saves
# still resolves; once such a save is loaded and re-saved it carries the new
# PEMK::ServerBadges, so this bridge only matters for legacy saves.
module PokeMMO; end unless defined?(PokeMMO)
PokeMMO::ServerBadges = PEMK::ServerBadges unless defined?(PokeMMO::ServerBadges)
