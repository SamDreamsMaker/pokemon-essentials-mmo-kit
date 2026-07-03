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
  # Badge index ceiling. Badges sync as ONE bitmask economy field (:badges); the
  # server stores it in a signed-bigint column, so the usable range is bits 0..62 =
  # 63 badges (all set == (1<<63)-1 == INT64 max == the server's derived :badges cap).
  # Far above any real region count (7 regions x 8 = 56). Single source of truth: the
  # encode clamp, the decode bound, and the server's badges_max all read as 63.
  BADGE_BITS = 63

  class ServerBadges < Array
    attr_accessor :pokemmo_silent   # when true, []= applies without notifying

    def []=(index, value)
      old    = (index >= 0 && index < length) ? self[index] : nil
      result = super
      # OBSERVER: on a REAL change, fold the whole (post-set) array into a bitmask and
      # push it as the absolute :badges economy value (coalesced by Sync). Normalize
      # the compare (!!old != !!value) so new-game init (old=nil vs value=false) isn't
      # a spurious mark. Clamp to bits 0..62: a truthy slot at index >= BADGE_BITS
      # would push the mask over the server cap and get the WHOLE field rejected
      # (rolling back every badge), so it is deliberately excluded from the mask.
      if !@pokemmo_silent && (!!old) != (!!value)
        mask = 0
        each_with_index { |v, i| mask |= (1 << i) if v && i < PEMK::BADGE_BITS }
        PEMK::Sync.mark_econ(:badges, mask)
        (PEMK::Sync.flush_event(:badge) rescue nil)   # badges are rare -> flush now, shrinking the force-quit-before-flush loss window
        (PEMK::Checkpoint.request(:badge) rescue nil) # checkpoint the surrounding gym story flags (defers past the ceremony)
      end
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

  # Trusted applier for server reconciliation (:econ_ack/:econ_rej for :badges, plus
  # reconcile-on-load): decode the authoritative bitmask onto the badges array. Silent
  # (never re-notifies) and ensure-guarded — an exception mid-loop must not leave the
  # instance permanently muted (which would silently stop syncing all future badges).
  # Writes ONLY genuine changes, so the array never balloons to length 63 and any core
  # UI keyed on badges.length stays undisturbed. Clears owned-in-blob-but-not-in-ledger
  # bits too (authoritative overwrite: the ledger wins).
  def pokemmo_apply_badges_mask(mask)
    return unless mask.is_a?(Integer)

    b = badges
    b.pokemmo_silent = true
    begin
      (0...PEMK::BADGE_BITS).each do |i|
        bit = ((mask >> i) & 1) == 1
        cur = (i < b.length) ? b[i] : nil
        next if (!!cur) == bit          # only write real changes
        b[i] = bit
      end
    ensure
      b.pokemmo_silent = false
    end
  end
end

# --- Backward compatibility with pre-rename saves --------------------------------
# Saves written before the PokeMMO -> PEMK rename stored $player.badges as a
# PokeMMO::ServerBadges. Alias the old constant so Marshal.load of those saves
# still resolves; once such a save is loaded and re-saved it carries the new
# PEMK::ServerBadges, so this bridge only matters for legacy saves.
module PokeMMO; end unless defined?(PokeMMO)
PokeMMO::ServerBadges = PEMK::ServerBadges unless defined?(PokeMMO::ServerBadges)
