#===============================================================================
# PEMK :: Dispatch
#-------------------------------------------------------------------------------
# Routes decoded inbound messages (from NetClient#poll) to the right handler.
# Kept tiny on purpose — the message protocol grows here as phases are added.
#===============================================================================
module PEMK
  # Text another player sent, as we may print it. pbMessage runs codes: a
  # "\ch[...]" in a name would set one of our game variables, "\se[...]" plays a
  # sound. The dedicated server cleans names too; this holds for any server.
  # Mirrors server/lib/pemk/plain_text.rb.
  NAME_MAX     = 16
  CHARSET_NAME = /\A[A-Za-z0-9_\- ]{1,64}\z/   # a Graphics/Characters file, no path

  def self.plain_name(value)
    plain_text(value, NAME_MAX)
  end

  # Any text the server relays for the player to read (a name, a ban's reason).
  def self.plain_text(value, max)
    return nil unless value.is_a?(String)

    s = value.dup.force_encoding(Encoding::UTF_8).scrub("")
    s = s.gsub(/[[:cntrl:]\p{Cf}\\<>]/, "").squeeze(" ").strip
    s = s[0, max].to_s.strip
    s.empty? ? nil : s
  end

  def self.plain_charset(value)
    value.is_a?(String) && value.match?(CHARSET_NAME) ? value : nil
  end

  module Dispatch
    # A frame's player-written fields, made safe before any handler sees them.
    def self.plain(msg)
      return msg unless msg.key?(:name) || msg.key?(:char)

      out = msg.dup
      { :name => :plain_name, :char => :plain_charset }.each do |key, cleaner|
        next unless out.key?(key)

        value = PEMK.send(cleaner, out[key])
        value ? out[key] = value : out.delete(key)
      end
      out
    end

    def self.handle(msg)
      return unless msg.is_a?(Hash)
      msg = plain(msg)
      case msg[:type]
      when :pos, :dir, :spawn, :step
        Remotes.apply_pos(msg)
      when :leave
        Remotes.remove(msg[:id])
      when :session_replaced
        NetStatus.on_replaced            # logged in elsewhere: this window stays offline
      when :banned
        NetStatus.on_banned(msg)         # the operator suspended the account: offline, told why
      when :save_ok, :save_err
        Sync.on_save_reply(msg)          # a pushed save written, or to be sent again
      when :trainer_battle_seed, :trainer_battle_deny
        BattleRng.on_trainer_seed(msg)   # a trainer battle's seed (trainer proof P2)
      when :battle_record_ack
        BattleRng.on_record_ack(msg)     # the server has a trainer battle's record (P4)
      when :flag_repair
        Flags.note_repair(msg)           # step 5: owned values back to the server's
      when :inv_correct
        ItemCorrect.receive(msg)         # E4: items the server could not account for, taken back
      when :pos_correct
        # M4 Layer B snap-back: server rejected our position -> return to the last-good
        # tile it sends. Applied on the next safe overworld frame. Only arrives when
        # server enforcement is :on.
        PosCorrect.request(msg[:map], msg[:x], msg[:y])
      when :trade_redeliver
        TradeRedeliver.on_redeliver(msg)   # a traded Pokemon the save never got
      when :shop_grant, :shop_deny
        Shop.on_reply(msg)               # E3: the answer to a :shop_req
      when :money_claim_ack
        PrizeClaim.on_ack(msg)           # money authority M1: a prize claim judged
      when :money_claim_ready
        PrizeClaim.on_ready(msg)         # P4: a held prize's proof is in - ask for it again
      when :gift_grant, :gift_deny
        GiftClaim.on_reply(msg)          # step 6: the answer to a :gift_req (keyed by nonce)
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
      when :catch_verdict, :catch_deny
        # M4 Layer D D3 (on): reply to a blocking :catch_req (keyed by seq).
        Catch.on_reply(msg)
      when :econ_ack, :econ_rej
        # Server's canonical economy balance: :econ_ack is the accepted value,
        # :econ_rej the current balance an over-cap/invalid change rolled back to.
        # Only the answer to the field's latest frame counts, as a delta on a change
        # still waiting to go out (Sync.econ_reply). The client reconciles to it via a
        # trusted, non-notifying applier (no echo back). :badges is a bitmask -> decode
        # it; money fields set directly.
        if $player && msg[:field] && msg[:value].is_a?(Integer)
          # M3: money the server refused - the game goes back to its balance, the money of
          # any prize claim released into that frame with it.
          if msg[:type] == :econ_rej && msg[:field] == :money && msg[:reason].to_s == "unexplained"
            (PrizeClaim.frame_refused rescue nil)
          end
          value = Sync.econ_reply(msg[:field], msg[:seq], msg[:value])
          if value.nil?
            nil
          elsif msg[:field] == :badges
            $player.pokemmo_apply_badges_mask(value)
          else
            $player.pokemmo_apply_economy(msg[:field], value)
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
      when :flags_ack
        # Switches/variables shadow telemetry (detection-only): log, never write.
        Flags.on_ack(msg)
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
        PosCorrect.reset                 # drop any un-applied snap-back from the dead session
        (ExpCorrect.reset rescue nil)    # ... and any un-applied EXP restore (M4-D6; rescued —
                                         # a fork missing 008 must not kill the reconnect FSM)
        (Flags.reset rescue nil)         # ... and the advertised flag-shadow mode
        (BattleRng.reset rescue nil)     # ... and any pending battle seed (M4-D7; a dead
                                         # session's seed must not arm a later battle)
        NetStatus.on_disconnect   # player notice + reconnect FSM (no-op pre-login)
      end
    end
  end
end
