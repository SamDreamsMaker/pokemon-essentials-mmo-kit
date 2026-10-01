# frozen_string_literal: true

require "json"
require_relative "money_claims"

module PEMK
  # Badge authority B1 (docs/BADGE-AUTHORITY-DESIGN.md): each badge a client says it got is
  # judged by the battle that gives it - the world export's sources and this account's
  # trainer prize claims with their replay's proof. Shadow: verdicts are logged, nothing
  # is refused.
  #   explained  - a win over a trainer whose win gives it, proven by its replay;
  #   pending    - such a win's record is on its claim's seed, its replay still to come;
  #   unprovable - such a win was claimed with no seed, or its record could not be
  #                replayed: no replay proves it (the server's side, or a seed lost);
  #   refused    - anything else: no source, no battle gives it, no such win claimed, or
  #                its win refuted or never recorded.
  class BadgeAudit
    KINDS = %w[trainer repeatable].freeze   # a trainer's prize (Pay Day's coins come won or lost)
    # A record whose draws are not its seed's (the seed walk at its ingest): no win.
    WALK_REFUTED = %w[walk_mismatch mode_mismatch no_log].freeze

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

    # yields for [claims, { seed row id => its won record's replay status }]
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
      won = ->(x) { (status = recorded[x[:trainer_battle_id]]) && !WALK_REFUTED.include?(status) }
      if (c = live.find { |x| x[:proof].nil? && won.(x) })
        return [:pending, "the win over #{names(c)} waits for its replay"]
      end
      if (c = live.find { |x| x[:proof] == "unprovable" || (x[:proof].nil? && x[:trainer_battle_id].nil?) })
        return [:unprovable, "the win over #{names(c)} #{c[:proof] ? 'could not be replayed' : 'was claimed with no seed'}"]
      end
      if (c = live.find { |x| x[:proof] })
        return [:refused, "the win over #{names(c)} is #{c[:proof]}"]
      end
      if (c = live.find { |x| recorded.key?(x[:trainer_battle_id]) })
        return [:refused, "the win over #{names(c)} has a record not drawn from its seed (#{recorded[c[:trainer_battle_id]]})"]
      end
      return [:refused, "the win over #{names(live[0])} has no record"] unless live.empty?

      [:refused, "no win over #{wins.flat_map { |s| s[:trainers] }.uniq.map { |t| "#{t[0]} #{t[1]}" }.join(' or ')} was claimed"]
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
      recorded = ids.empty? ? {} : @db[:battle_records].where(trainer_battle_id: ids, outcome: 1)
                                                       .select_hash(:trainer_battle_id, :replay_status)
      [claims, recorded]
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
