#===============================================================================
# PEMK :: Dispatch
#-------------------------------------------------------------------------------
# Routes decoded inbound messages (from NetClient#poll) to the right handler.
# Kept tiny on purpose — the message protocol grows here as phases are added.
#===============================================================================
module PEMK
  module Dispatch
    def self.handle(msg)
      return unless msg.is_a?(Hash)
      case msg[:type]
      when :pos, :dir, :spawn, :step
        Remotes.apply_pos(msg)
      when :leave
        Remotes.remove(msg[:id])
      when :econ_ack, :econ_rej
        # Server's canonical economy balance: :econ_ack is the accepted value,
        # :econ_rej the current balance an over-cap/invalid change rolled back to.
        # Either way the client reconciles to it via the trusted, non-notifying
        # setter (no echo back to the server).
        $player.pokemmo_apply_economy(msg[:field], msg[:value]) if $player && msg[:field] && msg[:value].is_a?(Integer)
      when :badge_ack
        $player.pokemmo_apply_badge(msg[:index], msg[:owned]) if $player && msg[:index].is_a?(Integer)
      when :challenge, :challenge_accept, :challenge_decline
        Challenge.on_message(msg)
      when :battle_team
        BattleSetup.on_team(msg)
      when :battle_start, :battle_choice, :battle_round, :battle_switch, :battle_end
        BattleNet.on_message(msg)
      when NetClient::DISCONNECTED
        PEMK.log("disconnected from server")
      end
    end
  end
end
