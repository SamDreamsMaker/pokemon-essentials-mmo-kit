#===============================================================================
# PEMK :: Inventory  (client side — M2.3, server-persistent bag)
#-------------------------------------------------------------------------------
# The bag (items) is mirrored to the server as an ABSOLUTE whole-bag snapshot
# {item_id => qty}: any bag mutation flags a coalesced :inv channel, and the WHOLE
# bag is read ONCE at flush and sent (PokemonBag stores @pockets = [[item_id, qty],
# ...] per pocket). Absolute + self-healing: a mutation path that bypasses
# add/remove is corrected at the very next flush because we re-read the whole bag.
#
# SERVER-PERSISTENT (like the economy): the server holds the bag and RESTORES it on
# login, so items persist WITHOUT a Game.save. On load the server bag OVERWRITES the
# client bag (apply_bag rebuilds the pockets via add). A brand-new/unseeded account
# (server sends inv = nil) keeps its blob bag and seeds the record on the first flush.
#
# NOT anti-cheat: the server trusts the client-reported bag (it cannot yet validate
# item ACQUISITION — that is M3). This buys server-side PERSISTENCE + a record, the
# same authority level as money/badges.
#
# Boxes / Pokémon storage are OUT OF SCOPE (they need M3 server-issued monster UIDs)
# and persist via the save blob for now.
#===============================================================================
module PEMK
  module Inventory
    @applying = false   # true while apply_bag rebuilds $bag -> the observers must NOT re-mark

    def self.applying
      @applying
    end

    # OBSERVER: a bag mutation just flags the channel (cheap); the whole-bag read
    # happens ONCE at flush (Sync.flush_primitives), not per op.
    def self.mark
      PEMK::Sync.mark_inv
    end

    # Seed the record from the current (blob-loaded) bag when the server has no
    # record yet: mark dirty so the first flush ships it.
    def self.capture_on_load
      PEMK::Sync.mark_inv
    end

    # Authoritative restore: rebuild $bag from the server's absolute snapshot
    # { item_id_symbol => qty }. Silent (the rebuild must not re-notify) and
    # ensure-guarded. add() derives each item's pocket from its GameData and drops
    # unknown ids.
    #
    # Under INFINITE pockets, core add() computes max_size = pocket.length + 1 once
    # per call, so a single add() fills at most ONE slot (<= BAG_MAX_PER_SLOT). A
    # stack larger than the per-slot cap (full_bag summed it across slots) MUST be
    # restored in per-slot chunks, or the overflow is silently dropped. break on a
    # falsey return (an unknown/renamed id refuses forever) so we never loop forever.
    def self.apply_bag(snapshot)
      return unless snapshot.is_a?(Hash) && $bag

      per_slot = (Settings::BAG_MAX_PER_SLOT rescue 999)
      per_slot = 999 unless per_slot.is_a?(Integer) && per_slot > 0
      @applying = true
      begin
        $bag.clear
        snapshot.each do |item_id, qty|
          next unless qty.is_a?(Integer) && qty > 0
          remaining = qty
          while remaining > 0
            chunk = [remaining, per_slot].min
            break unless ($bag.add(item_id, chunk) rescue nil)
            remaining -= chunk
          end
        end
      ensure
        @applying = false                        # never leave the observers muted, even on error
      end
    end

    # Flatten the live bag to { item_id_symbol => summed qty across all pockets/slots }.
    # Read on the GAME thread at flush; nil-guarded against odd pocket/slot shapes.
    def self.full_bag
      bag = $bag
      return nil unless bag && bag.respond_to?(:pockets) && bag.pockets

      snap = {}
      bag.pockets.each do |pocket|
        next unless pocket
        pocket.each do |slot|
          next unless slot.is_a?(Array) && slot[0]
          snap[slot[0]] = (snap[slot[0]] || 0) + slot[1].to_i
        end
      end
      snap
    rescue => e
      PEMK.log("inv: full_bag error: #{e.class}: #{e.message}")
      nil
    end

    # :inv_ack is telemetry — log a server structural flag; the applier is on login.
    def self.on_ack(msg)
      PEMK.log("inv: server flagged bag (seq #{msg[:seq]})") if msg && msg[:flagged]
    end
  end
end

# --- Bag: items -> mark the coalesced :inv channel on a real mutation -----------
# The !applying guard stops apply_bag's silent rebuild (clear + re-add) from
# re-marking the channel and echoing the just-restored bag back to the server.
class PokemonBag
  unless method_defined?(:pokemmo_orig_add)
    alias_method :pokemmo_orig_add,          :add
    alias_method :pokemmo_orig_remove,       :remove
    alias_method :pokemmo_orig_replace_item, :replace_item
    alias_method :pokemmo_orig_clear,        :clear

    def add(item, qty = 1)
      ret = pokemmo_orig_add(item, qty)
      PEMK::Inventory.mark if ret && !PEMK::Inventory.applying   # add_all/remove_all delegate here
      ret
    end

    def remove(item, qty = 1)
      ret = pokemmo_orig_remove(item, qty)
      PEMK::Inventory.mark if ret && !PEMK::Inventory.applying
      ret
    end

    def replace_item(old_item, new_item)
      ret = pokemmo_orig_replace_item(old_item, new_item)
      PEMK::Inventory.mark if ret && !PEMK::Inventory.applying
      ret
    end

    def clear
      ret = pokemmo_orig_clear
      PEMK::Inventory.mark unless PEMK::Inventory.applying
      ret
    end
  end
end
