# frozen_string_literal: true

require "json"

module PEMK
  # Read-only server model of the game's BATTLE reference data (Milestone 4 Layer D).
  # Loaded ONCE at boot from a build-time JSON export (server/data/battle_data.json)
  # produced IN-ENGINE by the client's "PEMK: Export Battle Data" debug action. Like
  # WorldData, the server NEVER reads a .dat/Marshal blob — that would need the engine's
  # GameData/RGSS classes and a Marshal.load of attacker-influenceable files, the exact
  # RCE surface M4 forbids. It only ever consumes plain JSON.
  #
  # Schema v1 is the PURE-DATA slice the anti-cheat needs — never move/ability/item
  # EFFECT code (a move's function_code is a dispatch KEY, not data):
  #   caps          {max_level, iv_stat_limit, ev_limit, ev_stat_limit, no_vitamin_ev_cap}
  #   natures       ID => [[STAT, +10|-10], ...]   ([] for neutral)
  #   growth_rates  ID => {max_exp}
  #   types         ATK => { DEF => 0|1|2|4 }      (engine scale; /2.0 = multiplier)
  #   abilities     [ID, ...]                      (existence set)
  #   items         ID => {pocket, is_ball, is_berry, is_machine, can_hold, move}
  #   moves         ID => {type, category, power, accuracy, pp, priority, target,
  #                        function_code, flags, effect_chance}
  #   species       ID => {species, form, types, base_stats, evs, base_exp, growth_rate,
  #                        catch_rate, abilities, hidden_abilities, level_up_moves,
  #                        tutor_moves, egg_moves, prev_species, minimum_level}
  # All IDs are Strings (JSON keys); callers normalize client-supplied ids with #to_s.
  #
  # Boot policy (same asymmetry as WorldData): ABSENT export -> tolerated (empty model +
  # one warning, so D1 team-legality just no-ops); PRESENT-but-INVALID (unparseable /
  # wrong schema_version / 'species' not an object) -> BOOT ERROR, so a stale/corrupt
  # export never boots silently.
  class BattleData
    SCHEMA_VERSION = 1
    NORMAL_EFFECT  = 2   # the type-matrix value for a neutral matchup (multiplier 1.0)

    def initialize(path, expected_version: SCHEMA_VERSION, logger: nil)
      @log          = logger || ->(_m) {}
      @caps         = {}
      @natures      = {}
      @growth_rates = {}
      @types        = {}
      @abilities    = {}   # id => true (a Set-like hash, for O(1) existence)
      @items        = {}
      @moves        = {}
      @species      = {}
      @loaded       = false
      load!(path, expected_version)
    end

    def loaded?; @loaded; end
    def empty?;  @species.empty?; end

    # --- species (D1 legality, D2 encounters, D4 rewards) ----------------------
    # -> frozen species entry hash | nil. +id+ is a String key ("BULBASAUR", "VENUSAUR_1").
    def species(id);        @species[id];        end
    def species_known?(id); @species.key?(id);   end

    # --- moves / abilities / natures / items (D1 legality) ---------------------
    def move(id);         @moves[id];          end
    def move_known?(id);  @moves.key?(id);      end
    def ability_known?(id); @abilities.key?(id); end
    def nature(id);       @natures[id];        end   # [[STAT, delta], ...] | nil
    def nature_known?(id); @natures.key?(id);  end
    def item(id);         @items[id];          end
    def item_known?(id);  @items.key?(id);     end

    # Can this item legally sit in a battler's held-item slot? Unknown item -> false
    # (a held item the export doesn't know about is not something we can vouch for).
    def holdable?(id)
      e = @items[id]
      e ? e["can_hold"] == true : false
    end

    # --- misc (used from D4 on; exposed now so the loader is complete) ----------
    def caps; @caps; end                                        # frozen {"max_level"=>100, ...}
    def max_level; @caps["max_level"]; end
    def growth_rate_max_exp(rate); g = @growth_rates[rate.to_s]; g && g["max_exp"]; end

    # Attacking x defending effectiveness on the engine scale (0/1/2/4); an unknown
    # pairing defaults to NORMAL so a missing cell never fabricates (in)effectiveness.
    def type_effectiveness(atk, dfn)
      row = @types[atk.to_s]
      return NORMAL_EFFECT unless row

      row.fetch(dfn.to_s, NORMAL_EFFECT)
    end

    def summary
      return "absent (Layer D no-op — run the in-game 'PEMK: Export Battle Data')" unless @loaded

      "#{@species.size} species/forms, #{@moves.size} moves, #{@items.size} items, " \
        "#{@abilities.size} abilities, #{@natures.size} natures (schema v#{SCHEMA_VERSION})"
    end

    private

    def load!(path, expected_version)
      unless File.file?(path)
        @log.call("battle-data: #{path} absent — Layer D team-legality runs in no-op mode until the in-game exporter is run")
        return
      end

      doc =
        begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise "battle data #{path} is not valid JSON: #{e.message}"
        end

      unless doc.is_a?(Hash) && doc["schema_version"] == expected_version
        got = doc.is_a?(Hash) ? doc["schema_version"].inspect : "missing"
        raise "battle data #{path} schema_version #{got} != expected #{expected_version} " \
              "(regenerate via the in-game 'PEMK: Export Battle Data' action)"
      end

      species = doc["species"]
      raise "battle data #{path} 'species' is not an object" unless species.is_a?(Hash)

      @caps         = freeze_hash(doc["caps"])
      @natures      = freeze_hash(doc["natures"])
      @growth_rates = freeze_hash(doc["growth_rates"])
      @types        = freeze_hash(doc["types"])
      @abilities    = load_id_set(doc["abilities"])
      @items        = freeze_hash(doc["items"])
      @moves        = freeze_hash(doc["moves"])
      @species      = freeze_hash(species)

      @loaded = true
      @log.call("battle-data: loaded #{summary} from #{path}")
    end

    # Freeze a String-keyed section and each of its top-level entry values, tolerating a
    # missing/mistyped section as empty (present-but-wrong-type is degraded, not fatal —
    # only 'species' is load-bearing enough to raise).
    def freeze_hash(h)
      return {} unless h.is_a?(Hash)

      h.each_value { |v| v.freeze }
      h.freeze
    end

    # ["OVERGROW", ...] -> { "OVERGROW" => true } for O(1) existence checks.
    def load_id_set(arr)
      return {} unless arr.is_a?(Array)

      set = {}
      arr.each { |id| set[id.to_s] = true if id }
      set.freeze
    end
  end
end
