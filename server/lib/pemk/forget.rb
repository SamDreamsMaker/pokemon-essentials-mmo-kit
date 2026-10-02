# frozen_string_literal: true

require_relative "bans"

module PEMK
  # The right to be forgotten, at the operator's console (bin/pemk_admin.rb forget), on a
  # player's request. The account's personal data goes (its email, name, password, its
  # sessions with their addresses) and so does its own game state (the save, the bag,
  # the party, the story flags, what it is owed); what other players' records and the
  # audit rely on stays, keyed by the opaque id - a Pokemon it issued that another player
  # holds, its trades, the ledger, its battles' records and proofs, its flags and bans. A
  # hard delete would break those, and let a cheater launder a history by asking.
  #
  # A ban row goes with it: the server closes a live connection within its ban sweep,
  # refuses a resume, and - once that connection's queued work is done (a last save would
  # bring the character back) - purges again. Forgetting twice changes nothing.
  class Forget
    # The tables the forgotten account's rows leave (each keyed by account_id)...
    GONE = %i[characters sessions inventory_snapshots party_snapshots flag_snapshots progression_facts
              event_cooldowns pickups gift_claims gift_grants badge_baselines trade_deliveries
              item_credits shop_deals money_shadow money_daily].freeze
    # ... and those whose rows stay, pseudonymous (nothing in them names the player).
    KEPT = %i[economy_ledger economy_balances badge_grants money_claims money_payouts battle_records
              trainer_battles encounter_rolls monsters monster_transfers enforcement_events
              player_flags anomaly_reports account_bans].freeze
    REASON = "account deleted at your request"

    def initialize(db)
      @db = db
    end

    # -> :forgotten, :already (forgotten before: purged again, nothing else), or nil (no
    # such account)
    def forget(account_id, by:, now: Time.now)
      @db.transaction do
        acct = @db[:accounts].where(id: account_id).first
        return nil unless acct

        first = acct[:forgotten_at].nil?
        if first
          @db[:accounts].where(id: account_id)
                        .update(email: nil, username: "forgotten-#{account_id}", password_hash: "forgotten",
                                status: "forgotten", failed_count: 0, locked_until: nil, last_login_at: nil,
                                forgotten_at: now)
          Bans.new(@db).ban(account_id, reason: REASON, by: by, now: now)   # the live kick, the resume refusal
        end
        purge(account_id)
        first ? :forgotten : :already
      end
    end

    # The account's own rows, gone - run again by the server once its queued work is
    # done. -> { table => rows removed }
    def purge(account_id)
      GONE.to_h { |t| [t, @db[t].where(account_id: account_id).delete] }
    end

    def forgotten?(account_id)
      !@db[:accounts].where(id: account_id).get(:forgotten_at).nil?
    end

    # The forgotten accounts among +account_ids+.
    def forgotten_among(account_ids)
      return [] if account_ids.empty?

      @db[:accounts].where(id: account_ids).exclude(forgotten_at: nil).select_map(:id)
    end
  end
end
