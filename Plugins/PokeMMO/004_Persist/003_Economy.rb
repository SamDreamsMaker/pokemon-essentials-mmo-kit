#===============================================================================
# PokeMMO :: Economy  (client side, Phase 2c-light)
#-------------------------------------------------------------------------------
# Routes the player's economy changes through the server: each setter applies
# optimistically (with the core clamp), then notifies the server, which re-clamps
# to the game cap and acks the canonical value. The client applies that ack via a
# trusted setter that does NOT re-notify (Dispatch :mutate_ack).
#
# This is a FOUNDATION, not full anti-cheat: a modified client can still lie in
# memory — only server-computed gameplay (a later phase) truly prevents that.
# What it buys now: a live authoritative record + hard-cap enforcement + the
# channel through which the server can later reject invalid changes.
#===============================================================================
module PokeMMO
  module Economy
    @last = {}   # field => last value sent (dedup redundant sets)

    def self.notify(field, value)
      c = PokeMMO.client
      return unless c && c.connected? && value.is_a?(Integer)
      return if @last[field] == value
      @last[field] = value
      c.send_message({ :type => :mutate, :field => field, :value => value })
    end

    def self.mark(field, value)   # keep dedup state in sync after a server ack
      @last[field] = value
    end
  end
end

class Player
  unless method_defined?(:pokemmo_orig_money=)
    alias_method :pokemmo_orig_money=,         :money=
    alias_method :pokemmo_orig_coins=,         :coins=
    alias_method :pokemmo_orig_battle_points=, :battle_points=
    alias_method :pokemmo_orig_soot=,          :soot=

    def money=(v)         ; self.pokemmo_orig_money = v         ; PokeMMO::Economy.notify(:money, @money)                 ; end
    def coins=(v)         ; self.pokemmo_orig_coins = v         ; PokeMMO::Economy.notify(:coins, @coins)                 ; end
    def battle_points=(v) ; self.pokemmo_orig_battle_points = v ; PokeMMO::Economy.notify(:battle_points, @battle_points) ; end
    def soot=(v)          ; self.pokemmo_orig_soot = v          ; PokeMMO::Economy.notify(:soot, @soot)                   ; end
  end

  # Trusted applier for server reconciliation (:mutate_ack) — never re-notifies.
  def pokemmo_apply_economy(field, value)
    case field
    when :money         then self.pokemmo_orig_money = value
    when :coins         then self.pokemmo_orig_coins = value
    when :battle_points then self.pokemmo_orig_battle_points = value
    when :soot          then self.pokemmo_orig_soot = value
    else return
    end
    PokeMMO::Economy.mark(field, value)
  end
end
