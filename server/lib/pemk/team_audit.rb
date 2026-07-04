# frozen_string_literal: true

module PEMK
  # M4 Layer D team/set LEGALITY audit (D1). Given a client-reported FULL-STAT team
  # (species/level/ivs/evs/moves/ability/nature/item — carried as primitives in the
  # envelope, never a Marshal blob), it validates every mon against the BattleData
  # read model: species/move/ability/nature/item existence, learnset membership
  # (self + pre-evolution chain: level-up ∪ tutor ∪ egg), the EV/IV/level caps, and
  # held-item legality. Party size is bounded by the same monster cap the registry
  # uses. Detection-first: it NEVER trusts the client and reports per-mon violations;
  # the mode only sets the log label and the (future) enforce hook — there is no
  # battle-entry gate to block yet in D1, so all modes LOG, matching audit-first.
  #
  # Absent battle_data -> unjudgeable no-op ({checked: false}), so a server without a
  # battle_data.json export never fabricates a rejection.
  class TeamAudit
    MODES = %i[off shadow on].freeze

    def initialize(battle_data, mode: :off, party_max: nil, logger: nil)
      @bd        = battle_data
      @mode      = MODES.include?(mode) ? mode : :off
      @party_max = party_max
      @log       = logger || ->(_m) {}
    end

    def mode; @mode; end
    def enforcing?; @mode == :on; end   # for a future battle/ranked-entry gate

    # team: Array of mon Hashes (String-keyed primitives from the wire).
    # -> { checked: false }                              (battle data absent)
    #  | { checked: true, legal: bool, team_violations: [..], mons: [{slot:,species:,violations:[..]}] }
    def check(account_id, team)
      return { checked: false } unless @bd.loaded?

      team = [] unless team.is_a?(Array)
      team_v = []
      team_v << "party_too_large:#{team.length}>#{@party_max}" if @party_max && team.length > @party_max

      # When the team is over-large it's already condemned (party_too_large); only scan
      # the legal-size prefix for per-mon detail so a malformed 4096-mon frame can't make
      # the reactor thread do unbounded work (authed frames aren't per-message limited).
      scan = (@party_max && team.length > @party_max) ? team.first(@party_max) : team
      mons = []
      scan.each_with_index do |m, i|
        vs = check_mon(m)
        next if vs.empty?

        mons << { slot: i, species: (m.is_a?(Hash) ? m["species"].to_s : nil), violations: vs }
      end

      legal = team_v.empty? && mons.empty?
      log_verdict(account_id, team_v, mons) unless legal
      { checked: true, legal: legal, team_violations: team_v, mons: mons }
    end

    private

    def check_mon(m)
      return ["not_an_object"] unless m.is_a?(Hash)

      species_id = m["species"].to_s
      sp = @bd.species(species_id)
      return ["unknown_species:#{species_id}"] unless sp   # nothing else is judgeable

      v = []
      check_level(m, sp, v)
      check_moves(m, species_id, v)
      check_ability(m, sp, v)
      check_nature(m, v)
      check_ivs(m, v)
      check_evs(m, v)
      check_item(m, v)
      v
    end

    def check_level(m, sp, v)
      lvl = m["level"]
      max = @bd.max_level
      if !lvl.is_a?(Integer) || lvl < 1 || (max && lvl > max)
        v << "level_out_of_range:#{lvl.inspect}"
        return
      end
      minl = sp["minimum_level"]
      v << "below_minimum_level:#{lvl}<#{minl}" if minl.is_a?(Integer) && lvl < minl
    end

    def check_moves(m, species_id, v)
      moves = m["moves"]
      return unless moves.is_a?(Array)

      pool = legal_move_pool(species_id)
      moves.each do |mv|
        id = mv.to_s
        next if id.empty?

        if !@bd.move_known?(id)
          v << "unknown_move:#{id}"
        elsif !pool.key?(id)
          v << "illegal_move:#{id}"
        end
      end
    end

    # Union over the family chain (self -> prev_species -> ...) of level-up move names
    # ∪ tutor_moves ∪ egg_moves — the move-relearner + TM/tutor + egg + pre-evo pool.
    # Cycle-guarded against a malformed prev_species loop in the export.
    def legal_move_pool(species_id)
      pool = {}
      seen = {}
      cur  = species_id
      while cur && !cur.empty? && !seen[cur]
        seen[cur] = true
        sp = @bd.species(cur)
        break unless sp

        Array(sp["level_up_moves"]).each { |p| pool[p[1].to_s] = true if p.is_a?(Array) && p[1] }
        Array(sp["tutor_moves"]).each { |mv| pool[mv.to_s] = true }
        Array(sp["egg_moves"]).each  { |mv| pool[mv.to_s] = true }
        prev = sp["prev_species"]
        cur  = prev && prev.to_s
      end
      pool
    end

    def check_ability(m, sp, v)
      ab = m["ability"].to_s
      return if ab.empty?

      legal = (Array(sp["abilities"]) + Array(sp["hidden_abilities"])).map(&:to_s)
      v << "illegal_ability:#{ab}" unless legal.include?(ab)
    end

    def check_nature(m, v)
      nat = m["nature"].to_s
      v << "unknown_nature:#{nat}" if !nat.empty? && !@bd.nature_known?(nat)
    end

    def check_ivs(m, v)
      cap = @bd.caps["iv_stat_limit"]
      return unless cap

      each_stat(m["ivs"]) { |stat, val| v << "iv_out_of_range:#{stat}=#{val}" if val < 0 || val > cap }
    end

    def check_evs(m, v)
      per   = @bd.caps["ev_stat_limit"]
      total = @bd.caps["ev_limit"]
      evs   = m["evs"]
      return unless evs.is_a?(Hash)

      each_stat(evs) { |stat, val| v << "ev_out_of_range:#{stat}=#{val}" if per && (val < 0 || val > per) }
      if total
        sum = evs.values.select { |x| x.is_a?(Integer) }.sum
        v << "ev_total_over:#{sum}>#{total}" if sum > total
      end
    end

    def check_item(m, v)
      it = m["item"].to_s
      return if it.empty?

      if !@bd.item_known?(it)
        v << "unknown_item:#{it}"
      elsif !@bd.holdable?(it)
        v << "unholdable_item:#{it}"
      end
    end

    def each_stat(h)
      return unless h.is_a?(Hash)

      h.each { |stat, val| yield(stat, val) if val.is_a?(Integer) }
    end

    def log_verdict(account_id, team_v, mons)
      label = case @mode
              when :on     then "REJECT"
              when :shadow then "WOULD-REJECT"
              else              "flag"
              end
      parts = team_v.dup
      mons.each { |mo| parts << "slot#{mo[:slot]}(#{mo[:species]}):#{mo[:violations].join(',')}" }
      shown = parts.first(12)
      shown << "(+#{parts.length - shown.length} more)" if parts.length > shown.length
      # Honest label: D1 has NO battle-entry gate, so even :on blocks nothing yet.
      @log.call("team: account #{account_id} #{label} illegal team [#{shown.join(' | ')}] (detection-only, no enforce gate yet)")
    end
  end
end
