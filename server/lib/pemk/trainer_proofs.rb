# frozen_string_literal: true

module PEMK
  # Trainer proof (docs/TRAINER-PROOF-DESIGN.md): a prize claim that names its battle's
  # seed gets a verdict from that battle's replay. The live server is the one writer: it
  # links a claim to its seed's row as it judges the claim, and a sweep reads the replay
  # tool's verdicts into the claims:
  #   proven     - a won battle, replayed to a match, the same prize, the player's team the
  #                server's own; the placement's seed is spent, the next battle gets another;
  #   refuted    - the record's draws are not the seed's, the replay disagrees, the team is
  #                not the server's, or the prize differs;
  #   unrecorded - no record of a won battle on the seed came in time: the client keeps
  #                the record until the server has it, so this is the client's doing;
  #   unprovable - a record the harness cannot replay, a trainer that is not the game's
  #                data (a game may edit its trainers as they load), a team the server
  #                cannot check yet: the server's side (paid from a small daily allowance
  #                under enforcement - Sam, 2026-09-29).
  # A record still waiting for its replay gives no verdict: the replay daemon's silence is
  # an alarm (stale), never a verdict. The sweep only decides; under enforcement the
  # client's next ask pays (P4).
  class TrainerProofs
    RECORD_WAIT = 600   # seconds a claim waits for its battle's record
    REPLAY_CHANNEL = "pemk_replay"   # NOTIFY: a record to replay (the replay daemon LISTENs)
    # The harness's word for a trainer the game's data does not build as the record has it
    # (server/harness/replay.rb).
    NOT_THE_DATA = "the trainer is not the game's data"

    def initialize(db, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
    end

    # -> the open seed row +seed+ names when it is this account's and the claim's own
    # trainer's, else nil.
    def seed_row(account_id, seed, trainers)
      return nil unless seed.is_a?(Integer) && seed.positive? && trainers.is_a?(Array) && trainers.length == 1

      # an open seed only (a spent one's win already paid), of this account, for this trainer
      row = @db[:trainer_battles].where(account_id: account_id, seed: seed, state: "open").first
      row && trainers[0] == [row[:tr_type], row[:tr_name], row[:tr_version], row[:map_id], row[:event_id]] ? row : nil
    end

    # The claim names its battle's seed: link it to the seed's row when the row is this
    # account's and names the claim's own trainer. -> the row id | nil. Safe inside the
    # claim's own transaction (a savepoint takes the unique index's refusal).
    def link_claim(account_id, nonce, seed, trainers)
      row = seed_row(account_id, seed, trainers)
      return nil unless row

      linked = @db.transaction(savepoint: true) do
        @db[:money_claims].where(account_id: account_id, nonce: nonce, trainer_battle_id: nil)
                          .update(trainer_battle_id: row[:id])
      end
      linked.positive? ? row[:id] : nil
    rescue Sequel::UniqueConstraintViolation   # another claim holds this battle: one win, one prize
      @log.call("trainerproof: account #{account_id} claim #{nonce} names a battle another claim holds")
      nil
    end

    # One pass over the linked claims still without a verdict.
    # -> [[account_id, nonce, proof, reason], ...] for the claims judged now.
    def sweep(now: Time.now)
      judged = []
      @stale = 0
      # "repeatable": a trainer fought again (the placements enforcement starts with)
      @db[:money_claims].where(proof: nil, voided_at: nil, kind: %w[trainer repeatable]).exclude(trainer_battle_id: nil)
                        .order(:created_at).limit(200).all.each do |claim|
        proof, record, reason = judge(claim, now)
        next unless proof

        settle(claim, proof, record, now)
        judged << [claim[:account_id], claim[:nonce], proof, reason]
      end
      judged
    end

    # The claims of the last sweep whose record waits for its replay past RECORD_WAIT.
    def stale
      @stale.to_i
    end

    private

    # -> [proof, record | nil, reason | nil], or nil while the verdict is still to come.
    def judge(claim, now)
      record = record_for(claim)
      late = now - claim[:created_at] > RECORD_WAIT
      return (late ? [:unrecorded, nil, "no record of a won battle on its seed"] : nil) unless record

      case record[:replay_status]
      when "walk_mismatch", "mode_mismatch", "no_log"
        [:refuted, record, "the record's draws are not its seed's (#{record[:replay_status]})"]
      when "mismatch"
        detail = record[:replay_detail].to_s
        return [:unprovable, record, detail] if detail.start_with?(NOT_THE_DATA)

        [:refuted, record, "the replay disagrees: #{detail}"]
      when "error", "not_replayable"
        [:unprovable, record, "the record could not be replayed (#{record[:replay_status]}: #{record[:replay_detail]})"]
      when "match"
        judge_match(claim, record)
      else   # pending, walk_ok, walk_skipped: not replayed yet - no verdict, however long
        @stale += 1 if late
        nil
      end
    end

    def judge_match(claim, record)
      case record[:team_check]
      when "refuted"    then return [:refuted, record, "the player's team: #{record[:replay_detail]}"]
      when "unprovable" then return [:unprovable, record, "the player's team: #{record[:replay_detail]}"]
      end
      prize = record[:replay_prize]
      return [:unprovable, record, "the replay paid no prize"] unless prize.is_a?(Integer)
      return [:refuted, record, "claimed #{claim[:amount]}, the replay paid #{prize}"] if prize != claim[:amount]

      [:proven, record, nil]
    end

    # The won battle on the claim's seed: a seed holds one (migration 044), and a claim holds
    # the seed - one win, one prize.
    def record_for(claim)
      @db[:battle_records].where(trainer_battle_id: claim[:trainer_battle_id], outcome: 1).first
    end

    def settle(claim, proof, record, now)
      @db.transaction do
        @db[:money_claims].where(account_id: claim[:account_id], nonce: claim[:nonce], proof: nil)
                          .update(proof: proof.to_s, proof_record_id: record && record[:id], proof_at: now)
        if proof == :proven   # the seed is spent: the next battle at this placement gets another
          @db[:trainer_battles].where(id: claim[:trainer_battle_id], state: "open")
                               .update(state: "proven", record_id: record[:id], closed_at: now)
        else
          # Judged without a win: the claim lets its battle go, and the record its seed's
          # one win - the seed stays, the next battle there runs on it again (a claim no
          # replay proves never buys a fresh seed).
          @db[:money_claims].where(account_id: claim[:account_id], nonce: claim[:nonce]).update(trainer_battle_id: nil)
          @db[:battle_records].where(id: record[:id]).update(trainer_battle_id: nil) if record
        end
      end
    end
  end
end
