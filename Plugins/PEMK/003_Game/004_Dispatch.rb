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
      when :pos_correct
        # M4 Layer B snap-back: server rejected our position -> return to the last-good
        # tile it sends. Applied on the next safe overworld frame. Only arrives when
        # server enforcement is :on.
        PosCorrect.request(msg[:map], msg[:x], msg[:y])
      when :pickup_grant, :pickup_deny, :pickups_reset_ok, :pickups_reset_deny
        # M4 Layer C: reply to a blocking :pickup_req or the dev-only :pickups_reset
        # (both keyed by seq, delete-on-read).
        Pickup.on_reply(msg)
      when :team_ack
        # M4 Layer D D1: the server's team-legality verdict (detection-only telemetry).
        TeamReport.on_ack(msg)
      when :encounter_grant, :encounter_deny
        # M4 Layer D D2 (on): reply to a blocking :encounter_req (keyed by seq).
        Encounter.on_reply(msg)
      when :econ_ack, :econ_rej
        # Server's canonical economy balance: :econ_ack is the accepted value,
        # :econ_rej the current balance an over-cap/invalid change rolled back to.
        # Either way the client reconciles to it via a trusted, non-notifying applier
        # (no echo back). :badges is a bitmask -> decode it; money fields set directly.
        if $player && msg[:field] && msg[:value].is_a?(Integer)
          if msg[:field] == :badges
            $player.pokemmo_apply_badges_mask(msg[:value])
          else
            $player.pokemmo_apply_economy(msg[:field], msg[:value])
          end
        end
      when :inv_ack
        # Detection-only telemetry: log a server flag, NEVER write $bag (the bag is
        # blob-authoritative in M2.3; there is no inventory applier). :inv_rej is
        # reserved for M3 server-authoritative rollback.
        Inventory.on_ack(msg)
      when :uid_grant
        # Server-minted monster identities: matched to instances by persisted nonce.
        Monsters.on_grant(msg)
      when :mon_ack
        # Party-projection telemetry (detection-only): log a flag, never write.
        Monsters.on_ack(msg)
      when :challenge, :challenge_accept, :challenge_decline
        Challenge.on_message(msg)
      when :trade_invite, :trade_accept, :trade_decline, :trade_offer, :trade_lock, :trade_cancel
        Trade.on_message(msg)          # peer handshake frames (ADDRESSED relay)
      when :trade_result
        Trade.on_result(msg)           # server-authoritative swap outcome
      when :battle_team
        BattleSetup.on_team(msg)
      when :battle_start, :battle_choice, :battle_round, :battle_switch, :battle_end
        BattleNet.on_message(msg)
      when NetClient::DISCONNECTED
        PEMK.log("disconnected from server")
        PosCorrect.reset          # drop any un-applied snap-back from the dead session
        NetStatus.on_disconnect   # player notice + reconnect FSM (no-op pre-login)
      end
    end
  end
end
