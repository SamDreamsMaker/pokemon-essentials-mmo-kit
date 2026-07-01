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
      when NetClient::DISCONNECTED
        PokeMMO.log("disconnected from server")
      end
    end
  end
end
