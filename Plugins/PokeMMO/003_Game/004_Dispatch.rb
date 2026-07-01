#===============================================================================
# PokeMMO :: Dispatch
#-------------------------------------------------------------------------------
# Routes decoded inbound messages (from NetClient#poll) to the right handler.
# Kept tiny on purpose — the message protocol grows here as phases are added.
#===============================================================================
module PokeMMO
  module Dispatch
    def self.handle(msg)
      return unless msg.is_a?(Hash)
      case msg[:type]
      when :pos, :dir, :spawn, :step
        Remotes.apply_pos(msg)
      when :leave
        Remotes.remove(msg[:id])
      when :mutate_ack
        # Server's canonical economy value (client applies it, no re-notify).
        $player.pokemmo_apply_economy(msg[:field], msg[:value]) if $player && msg[:value].is_a?(Integer)
      when :badge_ack
        $player.pokemmo_apply_badge(msg[:index], msg[:owned]) if $player && msg[:index].is_a?(Integer)
      when :challenge, :challenge_accept, :challenge_decline
        Challenge.on_message(msg)
      when NetClient::DISCONNECTED
        PokeMMO.log("disconnected from server")
      end
    end
  end
end
