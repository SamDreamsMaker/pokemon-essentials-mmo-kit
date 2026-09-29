# frozen_string_literal: true

module PEMK
  # Money authority M1a: the prizes clients claim and what they were judged to be worth,
  # and what each account has been paid for. A claim asked again gets its first verdict;
  # a battle is paid once, a rematch at most once per REMATCH_SEC per contact.
  class MoneyClaims
    NONCE       = (1...(1 << 62)).freeze
    REMATCH_SEC = 20 * 60   # the engine's own phone delay is 20 to 40 minutes
    PAID        = %w[paid suspect].freeze   # verdicts whose battles are paid for
    # Trainer proof P4: a claim held for its battle's proof reserves the battle's keys, and
    # one paid from the day's allowance for prizes no replay proves pays for the battle too.
    KEYED       = %w[paid suspect held allowance].freeze
    PAYDAY_SPENDS = %w[paid suspect capped].freeze   # Pay Day verdicts that use up their proof

    def initialize(db)
      @db = db
    end

    def self.nonce(value)
      value.is_a?(Integer) && NONCE.cover?(value) ? value : nil
    end

    def self.trainer_key(type, name, version)
      "trainer:#{type}:#{name}:#{version}"
    end

    # The branches of one page are one battle; a later page's battle (the win moved the
    # event on) is another. The first page keeps the key it always had.
    def self.event_key(map, event, page = 0)
      page.to_i.positive? ? "event:#{map}:#{event}:p#{page}" : "event:#{map}:#{event}"
    end

    # -> the recorded claim (a Hash), or nil
    def find(account_id, nonce)
      @db[:money_claims].where(account_id: account_id, nonce: nonce).first
    end

    # +credited+: what the server paid into the ledger for it (M3 enforcement; 0 in shadow).
    # Trainer proof P4: +trainer_battle_id+, the seed row of the battle a held claim waits
    # on; +proof+, why a claim was refused before any replay.
    def record(account_id, nonce, verdict:, mode:, amount:, accepted:, map:, trainers:, kind: "trainer", credited: 0,
               trainer_battle_id: nil, proof: nil, now: Time.now)
      row = { account_id: account_id, nonce: nonce, kind: kind, verdict: verdict, mode: mode.to_s,
              amount: amount, accepted: accepted, map: map, trainers: Sequel.pg_jsonb(trainers), credited: credited,
              created_at: now }
      row[:trainer_battle_id] = trainer_battle_id if trainer_battle_id
      row.merge!(proof: proof, proof_at: now) if proof
      @db[:money_claims].insert_conflict.insert(row)
    end

    # P4: does a claim already hold this seed row's battle? (one win, one prize)
    def seed_claimed?(trainer_battle_id)
      !@db[:money_claims].where(trainer_battle_id: trainer_battle_id).empty?
    end

    # P4: a held claim's end - what it was paid, once its proof came.
    def settle(account_id, nonce, verdict:, accepted:, credited:)
      @db[:money_claims].where(account_id: account_id, nonce: nonce, verdict: "held")
                        .update(verdict: verdict, accepted: accepted, credited: credited)
    end

    # M1c: a wild battle's foes, as the server minted them for this account - each roll
    # younger than MINT_SEC and never claimed for Pay Day. -> the rolls, or nil when one
    # is missing.
    MINT_SEC = 30 * 60

    def payday_rolls(account_id, pids, now: Time.now)
      rolls = pids.map do |pid|
        @db[:encounter_rolls].where(account_id: account_id, pid: pid, payday_at: nil)
                             .where { created_at > now - MINT_SEC }.order(Sequel.desc(:id)).first
      end
      rolls.all? ? rolls : nil
    end

    def stamp_payday(rolls, now: Time.now)
      @db[:encounter_rolls].where(id: rolls.map { |r| r[:id] }).update(payday_at: now)
    end

    # A trainer battle's prize claim backs one Pay Day claim.
    def stamp_prize_payday(account_id, nonce, now: Time.now)
      @db[:money_claims].where(account_id: account_id, nonce: nonce).update(payday_at: now)
    end

    # -> what Pay Day claims credited this account today (UTC day)
    # What the battles the game lets be fought again paid the account today (UTC).
    def repeat_today(account_id, now: Time.now)
      day = Time.utc(now.utc.year, now.utc.month, now.utc.day)
      @db[:money_claims].where(account_id: account_id, kind: "repeatable").where { created_at >= day }.sum(:accepted).to_i
    end

    def payday_today(account_id, now: Time.now)
      day = Time.utc(now.utc.year, now.utc.month, now.utc.day)
      @db[:money_claims].where(account_id: account_id, kind: "payday").where { created_at >= day }.sum(:accepted).to_i
    end


    # -> the payout row for +key+, or nil
    def payout(account_id, key)
      @db[:money_payouts].where(account_id: account_id, key: key).first
    end

    # Marks +keys+ paid by +nonce+; a rematch key already paid is paid again (its clock).
    def pay(account_id, keys, nonce, rematch:, now: Time.now)
      keys.each do |key|
        @db[:money_payouts].insert_conflict(target: %i[account_id key],
                                            update: { nonce: nonce, paid_at: now })
                           .insert(account_id: account_id, key: key, nonce: nonce, rematch: rematch, paid_at: now)
      end
    end

    # -> when a rematch contact (+type+, +name+) was last paid, or nil
    def rematch_clock(account_id, type, name)
      prefix = "trainer:#{type}:#{name}:"
      @db[:money_payouts].where(account_id: account_id, rematch: true).select_map(%i[key paid_at])
                         .select { |key, _| key.start_with?(prefix) }.map(&:last).max
    end

    # The first fresh money frame after a claim: its prize reached the ledger. A claim held
    # for its proof (P4) paid nothing yet: only a save whose list of claims names it (+held+,
    # the nonces in the saved blob - what a fresh login loads again) seals it.
    def seal(account_id, held: nil, now: Time.now)
      ds = @db[:money_claims].where(account_id: account_id, sealed_at: nil, voided_at: nil)
      ds.exclude(verdict: "held").update(sealed_at: now)
      ds.where(verdict: "held", nonce: held).update(sealed_at: now) if held.is_a?(Array) && !held.empty?
    end

    # A fresh login: a claim still unsealed may be missing from the save that loads - the
    # battle it paid for can be fought again, so its payouts go. The block, given each such
    # claim, undoes its payment and says whether it could: a claim it could not undo is
    # kept, sealed. -> the claims voided
    def void_unsealed(account_id, now: Time.now)
      rows = @db[:money_claims].where(account_id: account_id, sealed_at: nil, voided_at: nil, verdict: KEYED).all
      rows.select do |c|
        undone = block_given? ? yield(c) : true
        if undone
          @db[:money_payouts].where(account_id: account_id, nonce: c[:nonce]).delete
          # its battle's seed row is free again, and the seed's one win with it: the battle
          # fought again names the seed, and is judged on its own record (P4)
          @db[:money_claims].where(account_id: account_id, nonce: c[:nonce]).update(voided_at: now, trainer_battle_id: nil)
          if c[:trainer_battle_id]
            @db[:battle_records].where(trainer_battle_id: c[:trainer_battle_id], outcome: 1).update(trainer_battle_id: nil)
          end
        else
          @db[:money_claims].where(account_id: account_id, nonce: c[:nonce]).update(sealed_at: now)
        end
        undone
      end
    end
  end
end
