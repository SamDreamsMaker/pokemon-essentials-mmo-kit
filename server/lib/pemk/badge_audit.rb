# frozen_string_literal: true

require "json"
require_relative "money_claims"
require_relative "trainer_proofs"

module PEMK
  # Badge authority (docs/BADGE-AUTHORITY-DESIGN.md): each badge a client says it got is
  # judged by the battle that gives it - the world export's sources and this account's
  # trainer prize claims with their replay's proof.
  #   explained  - a win over a trainer whose win gives it, proven by its replay;
  #   pending    - such a win's record is on its claim's seed, its replay not decided yet;
  #   unprovable - such a win was claimed with no seed, or its record could not be
  #                replayed: no replay proves it (the server's side, or a seed lost);
  #   refused    - anything else: no source, no battle gives it, no such win claimed, or
  #                its win refuted or never recorded.
  # B1 (shadow) logs the verdicts; B2 (enforcement) owns the proven, shows the pending.
  class BadgeAudit
    KINDS = %w[trainer repeatable].freeze   # a trainer's prize (Pay Day's coins come won or lost)
    # A record whose draws are not its seed's (the seed walk at its ingest): no win.
    WALK_REFUTED = %w[walk_mismatch mode_mismatch no_log].freeze
    UNREPLAYABLE = %w[error not_replayable].freeze

    def initialize(db, world)
      @db = db
      @world = world
    end

    # -> [[badge, verdict, why], ...] for the bits +new_bits+ sets (a bitmask: what the
    # frame adds to the ledger's).
    def judge(account_id, new_bits)
      bits = bits_of(new_bits)
      return [] if bits.empty?

      seen = nil   # the account's claims and won records: read once, and only for a badge a battle gives
      bits.map { |badge| [badge, *judge_bit(badge) { seen ||= claims_seen(account_id) }] }
    end

    # -> the badges a claim's win gives, for a trainer's prize claim that pays (what B2
    # grants at its proof).
    def wins_of(account_id, nonce)
      claim = @db[:money_claims].where(account_id: account_id, nonce: nonce, kind: KINDS, verdict: MoneyClaims::KEYED).first
      claim ? wins_in(claim) : []
    end

    # -> the badges a claim row's win gives
    def wins_in(claim)
      trainers_of(claim).flat_map { |t| @world.win_bits(t[3], t[4], t[0], t[1], t[2]) }.uniq.sort
    end

    # B2: the badges the account's wins still waiting for their replay will give - shown,
    # not owned. -> mask
    def pending_bits(account_id)
      claims, recorded = claims_seen(account_id)
      claims.select { |c| !c[:voided_at] && c[:proof].nil? && record_state(recorded[c[:trainer_battle_id]]) == :open }
            .flat_map { |c| wins_in(c) }.uniq.sum { |b| 1 << b }
    end

    # B2: the badges the account's wins no replay can prove would give - claimed with no
    # seed, or not replayable. -> mask
    def unprovable_bits(account_id)
      claims, recorded = claims_seen(account_id)
      claims.select do |c|
        next false if c[:voided_at]

        c[:proof] == "unprovable" ||
          (c[:proof].nil? && (c[:trainer_battle_id].nil? || record_state(recorded[c[:trainer_battle_id]]) == :unprovable))
      end.flat_map { |c| wins_in(c) }.uniq.sum { |b| 1 << b }
    end

    # -> the badges the account's grants own (badge_grants)
    def granted_bits(account_id)
      @db[:badge_grants].where(account_id: account_id).select_map(:badge).uniq.sum { |b| 1 << b }
    end

    # B2's boot pass for one account whose ledger holds +held+: what it owns, at the first
    # cutover (+cutover+) its badges from before the authority too. -> { owned:, legacy:,
    # proof: { badge => claim nonce }, pending:, refused: [[badge, why]], unprovable: [...] }
    def plan(account_id, held, cutover:)
      granted = granted_bits(account_id)
      legacy = cutover ? legacy_of(account_id, held) & ~granted : 0
      proof = {}
      proven_claims(account_id).each do |c|
        wins_in(c).each { |b| proof[b] ||= c[:nonce] if (granted | legacy)[b].zero? }
      end
      owned = granted | legacy | proof.keys.sum { |b| 1 << b }
      pending = pending_bits(account_id) & ~owned
      verdicts = judge(account_id, held & ~(owned | pending))
      { owned: owned, legacy: legacy, proof: proof, pending: held & pending,
        refused: verdicts.reject { |_, v, _| v == :unprovable }.map { |b, _, why| [b, why] },
        unprovable: verdicts.select { |_, v, _| v == :unprovable }.map { |b, _, why| [b, why] } }
    end

    # The ledger's badges before the account's first judged frame: B2's cutover takes them
    # as earned before the badge authority. -> the mask kept (the first one stays)
    def baseline(account_id, mask, now: Time.now)
      @db[:badge_baselines].insert_conflict(target: :account_id)
                           .insert(account_id: account_id, mask: mask.to_i, taken_at: now)
      baseline_of(account_id)
    end

    # -> the account's baseline, or nil: never judged (what it holds predates the authority)
    def baseline_of(account_id)
      @db[:badge_baselines].where(account_id: account_id).get(:mask)&.to_i
    end

    def bits_of(mask)
      return [] unless mask.is_a?(Integer) && mask.positive?

      (0...mask.bit_length).select { |i| mask[i] == 1 }
    end

    private

    # yields for [claims, { seed row id => [its won record's replay status, team check, detail] }]
    def judge_bit(badge)
      sources = @world.badge_sources(badge)
      return [:refused, "the exports do not say what gives badges"] if sources.nil?
      return [:refused, "nothing the exports read gives it"] if sources.empty?

      wins = sources.select { |s| s[:trainers] }
      return [:refused, "no battle gives it"] if wins.empty?

      claims, recorded = yield
      mine = claims.select { |c| trainers_of(c).any? { |t| @world.win_bits(t[3], t[4], t[0], t[1], t[2]).include?(badge) } }
      if (c = mine.find { |x| x[:proof] == "proven" })
        return [:explained, "the win over #{names(c)} is proven"]
      end
      # (a voided claim counts only proven: its badge was the account's at the proof)
      live = mine.reject { |x| x[:voided_at] }
      state = ->(x) { x[:proof].nil? ? record_state(recorded[x[:trainer_battle_id]]) : nil }
      if (c = live.find { |x| state.(x) == :open })
        return [:pending, "the win over #{names(c)} waits for its replay"]
      end
      if (c = live.find { |x| x[:proof] == "unprovable" || state.(x) == :unprovable })
        return [:unprovable, "the win over #{names(c)} could not be replayed"]
      end
      if (c = live.find { |x| x[:proof].nil? && x[:trainer_battle_id].nil? })
        return [:unprovable, "the win over #{names(c)} was claimed with no seed"]
      end
      if (c = live.find { |x| x[:proof] })
        return [:refused, "the win over #{names(c)} is #{c[:proof]}"]
      end
      if (c = live.find { |x| state.(x) == :walk })
        return [:refused, "the win over #{names(c)} has a record not drawn from its seed (#{recorded[c[:trainer_battle_id]][0]})"]
      end
      if (c = live.find { |x| state.(x) == :refuted })
        return [:refused, "the win over #{names(c)}: its replay disagrees"]
      end
      return [:refused, "the win over #{names(live[0])} has no record"] unless live.empty?

      [:refused, "no win over #{wins.flat_map { |s| s[:trainers] }.uniq.map { |t| "#{t[0]} #{t[1]}" }.join(' or ')} was claimed"]
    end

    # A won record's replay, as a badge sees it: :open (not decided - pending, walked, or
    # a match whose team check stands), :walk (its draws are not its seed's), :refuted (its
    # replay disagrees, or its team is not the server's), :unprovable (it could not be
    # replayed), or nil (no won record).
    def record_state(record)
      return nil unless record

      status, team, detail = record
      return :walk if WALK_REFUTED.include?(status)
      return :unprovable if UNREPLAYABLE.include?(status) || team == "unprovable"
      return :unprovable if status == "mismatch" && detail.to_s.start_with?(TrainerProofs::NOT_THE_DATA)
      return :refuted if status == "mismatch" || team == "refuted"

      :open
    end

    # The account's trainer prize claims that may explain a badge - not voided unless
    # proven, and a verdict that pays (a claim away from its trainer, for a trainer the
    # exports do not place, or out of order explains nothing) - and the seed rows holding
    # a won record, with its replay's status.
    def claims_seen(account_id)
      claims = @db[:money_claims].where(account_id: account_id, kind: KINDS, verdict: MoneyClaims::KEYED)
                                 .where(Sequel.|({ voided_at: nil }, { proof: "proven" }))
                                 .select(:nonce, :trainers, :proof, :trainer_battle_id, :voided_at).all
      ids = claims.filter_map { |c| c[:trainer_battle_id] }
      recorded = {}
      unless ids.empty?
        @db[:battle_records].where(trainer_battle_id: ids, outcome: 1)
                            .select(:trainer_battle_id, :replay_status, :team_check, :replay_detail).each do |r|
          recorded[r[:trainer_battle_id]] = [r[:replay_status], r[:team_check], r[:replay_detail]]
        end
      end
      [claims, recorded]
    end

    # The account's proven wins, their claims voided since or not (B2 granted them at the
    # proof).
    def proven_claims(account_id)
      @db[:money_claims].where(account_id: account_id, kind: KINDS, verdict: MoneyClaims::KEYED, proof: "proven")
                        .select(:nonce, :trainers).all
    end

    # The badges the account held before the authority judged it: its baseline, or (never
    # judged) all it holds.
    def legacy_of(account_id, held)
      base = baseline_of(account_id)
      base ? held & base : held
    end

    # [[type, name, version, map, event], ...] (jsonb as text or as an array)
    def trainers_of(claim)
      list = claim[:trainers]
      list = JSON.parse(list) if list.is_a?(String)
      Array(list).select { |t| t.is_a?(Array) && t.length == 5 }
    rescue JSON::ParserError
      []
    end

    def names(claim)
      trainers_of(claim).map { |t| "#{t[0]} #{t[1]}" }.join(", ")
    end
  end
end
