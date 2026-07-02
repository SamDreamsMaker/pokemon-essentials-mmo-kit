#===============================================================================
# PEMK :: Inventory  (client side, Phase 2c-light)
#-------------------------------------------------------------------------------
# Reports bag (item) and box (Pokémon storage) changes to the server via a single
# :inv message with an :op. Notify-only for now: unlike money/badges there is no
# single canonical value to clamp+ack, so the server just logs the operation
# (foundation/observability). Server-side inventory validation is a later phase.
#===============================================================================
module PEMK
  module Inventory
    def self.notify(op, extra = {})
      c = PEMK.client
      return unless c && c.connected?
      c.send_message({ :type => :inv, :op => op }.merge(extra))
    end
  end
end

# --- Bag: items ---------------------------------------------------------------
class PokemonBag
  unless method_defined?(:pokemmo_orig_add)
    alias_method :pokemmo_orig_add,    :add
    alias_method :pokemmo_orig_remove, :remove

    def add(item, qty = 1)
      ret = pokemmo_orig_add(item, qty)
      PEMK::Inventory.notify(:bag_add, { :item => item, :qty => qty }) if ret
      ret
    end

    def remove(item, qty = 1)
      ret = pokemmo_orig_remove(item, qty)
      PEMK::Inventory.notify(:bag_remove, { :item => item, :qty => qty }) if ret
      ret
    end
  end
end

# --- Boxes: Pokémon storage ---------------------------------------------------
class PokemonStorage
  unless method_defined?(:pokemmo_orig_pbStoreCaught)
    alias_method :pokemmo_orig_pbStoreCaught, :pbStoreCaught
    alias_method :pokemmo_orig_pbMove,        :pbMove
    alias_method :pokemmo_orig_pbDelete,      :pbDelete

    def pbStoreCaught(pkmn)
      box = pokemmo_orig_pbStoreCaught(pkmn)
      PEMK::Inventory.notify(:box_store, { :box => box }) if box && box >= 0
      box
    end

    def pbMove(boxDst, indexDst, boxSrc, indexSrc)
      ret = pokemmo_orig_pbMove(boxDst, indexDst, boxSrc, indexSrc)
      PEMK::Inventory.notify(:box_move, { :box => boxDst, :index => indexDst }) if ret
      ret
    end

    def pbDelete(box, index)
      ret = pokemmo_orig_pbDelete(box, index)
      PEMK::Inventory.notify(:box_delete, { :box => box, :index => index })
      ret
    end
  end
end
