# frozen_string_literal: true

require "date"

module PEMK
  # Money authority: per account and day (UTC), the money of sales no source the server
  # owns explains - local-tier units it never sold itself. PEMK_MONEY_LOCAL_DAILY bounds it.
  # And the trainer prizes paid without a proof (PEMK_MONEY_UNPROVEN_DAILY).
  # Every call runs on the account's mailbox, or inside its deal's transaction.
  class MoneyDaily
    def initialize(db)
      @db = db
    end

    def local_sold(account_id, now: Time.now)
      @db[:money_daily].where(account_id: account_id, day: now.utc.to_date).get(:local_sold).to_i
    end

    def add_local(account_id, amount, now: Time.now)
      return unless amount.positive?

      @db[:money_daily].insert_conflict(target: %i[account_id day],
                                        update: { local_sold: Sequel[:money_daily][:local_sold] + amount })
                       .insert(account_id: account_id, day: now.utc.to_date, local_sold: amount)
    end

    # Trainer proof P4: the prizes paid today without a proof (PEMK_MONEY_UNPROVEN_DAILY).
    def unproven_paid(account_id, now: Time.now)
      @db[:money_daily].where(account_id: account_id, day: now.utc.to_date).get(:unproven_paid).to_i
    end

    def add_unproven(account_id, amount, now: Time.now)
      return unless amount.positive?

      @db[:money_daily].insert_conflict(target: %i[account_id day],
                                        update: { unproven_paid: Sequel[:money_daily][:unproven_paid] + amount })
                       .insert(account_id: account_id, day: now.utc.to_date, unproven_paid: amount)
    end
  end
end
