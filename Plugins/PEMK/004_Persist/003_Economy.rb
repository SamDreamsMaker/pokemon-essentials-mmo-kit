#===============================================================================
# PEMK :: Economy  (client side, Phase 2c-light)
#-------------------------------------------------------------------------------
# Routes the player's economy changes through the server: each setter applies
# optimistically (with the core clamp), then notifies the server, which re-clamps
# to the game cap and acks the canonical value. The client applies that ack via a
# trusted setter that does NOT re-notify (Dispatch :econ_ack / :econ_rej).
#
# This is a FOUNDATION, not full anti-cheat: a modified client can still lie in
# memory — only server-computed gameplay (a later phase) truly prevents that.
# What it buys now: a live authoritative record + hard-cap enforcement + the
# channel through which the server can later reject invalid changes.
#===============================================================================
module PEMK
  module Economy
    # OBSERVER: the setter aliases below call notify, which now feeds the Sync
    # dirty-set (coalesced + flushed on events/quiescence) instead of writing the
    # socket per mutation. mark() is the reconcile hook the server ack will use
    # (M2.1) to keep the client baseline in step without re-notifying.
    def self.notify(field, value)
      return unless value.is_a?(Integer)

      PEMK::Sync.mark_econ(field, value)
    end

    def self.mark(_field, _value); end
  end
end

class Player
  unless method_defined?(:pokemmo_orig_money=)
    alias_method :pokemmo_orig_money=,         :money=
    alias_method :pokemmo_orig_coins=,         :coins=
    alias_method :pokemmo_orig_battle_points=, :battle_points=
    alias_method :pokemmo_orig_soot=,          :soot=

    def money=(v)         ; self.pokemmo_orig_money = v         ; PEMK::Economy.notify(:money, @money)                 ; end
    def coins=(v)         ; self.pokemmo_orig_coins = v         ; PEMK::Economy.notify(:coins, @coins)                 ; end
    def battle_points=(v) ; self.pokemmo_orig_battle_points = v ; PEMK::Economy.notify(:battle_points, @battle_points) ; end
    def soot=(v)          ; self.pokemmo_orig_soot = v          ; PEMK::Economy.notify(:soot, @soot)                   ; end
  end

  # Trusted applier for server reconciliation (:econ_ack/:econ_rej + reconcile-on-
  # load) — sets the canonical balance and never re-notifies the server.
  def pokemmo_apply_economy(field, value)
    case field
    when :money         then self.pokemmo_orig_money = value
    when :coins         then self.pokemmo_orig_coins = value
    when :battle_points then self.pokemmo_orig_battle_points = value
    when :soot          then self.pokemmo_orig_soot = value
    else return
    end
    PEMK::Economy.mark(field, value)
  end
end
