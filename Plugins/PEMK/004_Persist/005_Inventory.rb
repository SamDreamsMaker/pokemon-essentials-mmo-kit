#===============================================================================
# PEMK :: Inventory  (client side — M2.3)
#-------------------------------------------------------------------------------
# The bag (items) is mirrored to the server as an ABSOLUTE whole-bag snapshot
# {item_id => qty}, coalesced through Sync exactly like the economy: any bag
# mutation just marks the :inv channel dirty, and the WHOLE bag is read ONCE at
# flush (PokemonBag stores @pockets = [[item_id, qty], ...] per pocket). Absolute +
# self-healing: a mutation path that bypasses add/remove is corrected at the very
# next flush because we re-read the entire bag.
#
# DETECTION-ONLY (M2.3): the server RECORDS + structurally flags but never rejects,
# and the bag stays BLOB-AUTHORITATIVE — so there is deliberately NO applier that
# writes $bag from the server (unlike economy/badges). on_ack only logs a flag.
#
# Boxes / Pokémon storage are OUT OF SCOPE (they need M3 server-issued monster UIDs)
# and persist via the save blob for now — their hooks were retired with the old
# in-process host and return with M3.
#===============================================================================
module PEMK
  module Inventory
    # OBSERVER: a bag mutation just flags the channel (cheap); the whole-bag read
    # happens ONCE at flush (Sync.flush_primitives), not per op.
    def self.mark
      PEMK::Sync.mark_inv
    end

    # Reconcile-on-load: mark dirty so the first debounced flush after entering the
    # world ships the loaded bag and the server record converges. NEVER writes $bag.
    def self.capture_on_load
      PEMK::Sync.mark_inv
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

    # :inv_ack is detection-only telemetry — log a flag, NEVER touch $bag.
    def self.on_ack(msg)
      PEMK.log("inv: server flagged bag (seq #{msg[:seq]})") if msg && msg[:flagged]
    end
  end
end

# --- Bag: items -> mark the coalesced :inv channel on a real mutation -----------
class PokemonBag
  unless method_defined?(:pokemmo_orig_add)
    alias_method :pokemmo_orig_add,          :add
    alias_method :pokemmo_orig_remove,       :remove
    alias_method :pokemmo_orig_replace_item, :replace_item
    alias_method :pokemmo_orig_clear,        :clear

    def add(item, qty = 1)
      ret = pokemmo_orig_add(item, qty)
      PEMK::Inventory.mark if ret          # add_all/remove_all delegate here -> covered transitively
      ret
    end

    def remove(item, qty = 1)
      ret = pokemmo_orig_remove(item, qty)
      PEMK::Inventory.mark if ret
      ret
    end

    # replace_item (mutates item[0] in place) and clear bypass add/remove; alias them
    # so the stale window shrinks — the absolute snapshot self-heals at the next flush.
    def replace_item(old_item, new_item)
      ret = pokemmo_orig_replace_item(old_item, new_item)
      PEMK::Inventory.mark if ret
      ret
    end

    def clear
      ret = pokemmo_orig_clear
      PEMK::Inventory.mark
      ret
    end
  end
end
