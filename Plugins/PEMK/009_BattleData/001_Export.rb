#===============================================================================
# PEMK :: BattleDataExport  (client side — M4 Layer D, build-time battle-data export)
#-------------------------------------------------------------------------------
# Mirrors the Layer A world exporter (008_World/002_Export.rb): a debug-menu action
# ("PEMK: Export Battle Data") walks the compiled GameData at build time and writes a
# PURE-DATA JSON to server/data/battle_data.json that the headless MRI server loads
# (server/lib/pemk/battle_data.rb) to validate team/set LEGALITY (D1), mint encounters
# (D2), adjudicate catches (D3) and bound rewards (D4).
#
# It exports DATA only — never move/ability/item EFFECT code (a move's function_code
# is a dispatch KEY, not data; the ~30k-line 011_Battle effect tree is the engine tier,
# out of scope here). It NEVER writes a .dat/Marshal blob: the server has no RGSS and
# cannot Marshal.load an engine struct. Runs from the F9 debug menu, so it never ships
# in a player build and edits no core Essentials script (reads GameData + registers a
# menu handler only). Re-run it after any species/move/PBS edit.
#
# The recursive JSON writer is reused from PEMK::WorldExport (mkxp-z has no reliable
# `json`); both are the same plugin, so the coupling is intentional.
#===============================================================================
module PEMK
  module BattleDataExport
    SCHEMA_VERSION = 1
    OUT_PATH       = "server/data/battle_data.json"   # relative to the game root (cwd)

    module_function

    # --- pure builders (driven by fake structs in the headless proof) ----------

    # One species/form entry. Forms are separate GameData entries already MERGED with
    # their base at compile time, so we read the entry's own accessors directly.
    def species_entry(sp)
      base_stats = {}
      sp.base_stats.each { |k, v| base_stats[k.to_s] = v }
      evs = {}
      sp.evs.each { |k, v| evs[k.to_s] = v }

      prev = sp.get_previous_species
      prev = nil if prev.nil? || prev.to_s == sp.species.to_s   # self == no pre-evolution

      {
        "species"          => sp.species.to_s,        # base id (form-independent)
        "form"             => sp.form,                # 0 = base form
        "types"            => sp.types.map(&:to_s),
        "base_stats"       => base_stats,             # {"HP"=>45, "ATTACK"=>49, ...}
        "evs"              => evs,                    # EV yield when defeated
        "base_exp"         => sp.base_exp,
        "growth_rate"      => sp.growth_rate.to_s,    # a Symbol on the species; a key into :growth_rates
        "catch_rate"       => sp.catch_rate,
        "abilities"        => sp.abilities.map(&:to_s),
        "hidden_abilities" => sp.hidden_abilities.map(&:to_s),
        # level-up learnset as [level, MOVE] pairs, sorted ascending (source order is PBS order)
        "level_up_moves"   => sp.moves.sort_by { |m| m[0] }.map { |m| [m[0], m[1].to_s] },
        "tutor_moves"      => sp.tutor_moves.map(&:to_s),   # combined TM/HM/tutor pool in v21.1
        "egg_moves"        => sp.egg_moves.map(&:to_s),
        "prev_species"     => (prev && prev.to_s),    # immediate pre-evolution id (String), or null
        "minimum_level"    => sp.minimum_level
      }
    end

    def move_entry(mv)
      {
        "type"          => mv.type.to_s,
        "category"      => mv.category,               # 0 Physical / 1 Special / 2 Status (Integer)
        "power"         => mv.power,
        "accuracy"      => mv.accuracy,
        "pp"            => mv.total_pp,
        "priority"      => mv.priority,
        "target"        => mv.target.to_s,
        "function_code" => mv.function_code.to_s,     # effect dispatch KEY (String), not data
        "flags"         => mv.flags.map(&:to_s),
        "effect_chance" => mv.effect_chance
      }
    end

    def item_entry(it)
      {
        "pocket"     => it.pocket,
        "is_ball"    => !!it.is_poke_ball?,
        "is_berry"   => !!it.is_berry?,
        "is_machine" => !!it.is_machine?,             # TM/HM/TR
        "can_hold"   => !!it.can_hold?,               # held-item legality (= !important)
        "move"       => (it.move ? it.move.to_s : nil) # taught move for a machine, else null
      }
    end

    # Full attacking x defending effectiveness matrix, as integers on the engine scale
    # (0 immune, 1 not-very, 2 normal, 4 super); divide by 2.0 for the multiplier.
    def type_matrix
      matrix = {}
      atk_types = []
      GameData::Type.each { |t| atk_types << t unless t.pseudo_type }
      atk_types.each do |atk|
        row = {}
        atk_types.each { |dfn| row[dfn.id.to_s] = dfn.effectiveness(atk.id) }
        matrix[atk.id.to_s] = row
      end
      matrix
    end

    def natures_map
      out = {}
      GameData::Nature.each do |n|
        out[n.id.to_s] = n.stat_changes.map { |c| [c[0].to_s, c[1]] }   # [] for neutral natures
      end
      out
    end

    def growth_rates_map
      out = {}
      GameData::GrowthRate.each { |gr| out[gr.id.to_s] = { "max_exp" => gr.maximum_exp } }
      out
    end

    def abilities_list
      out = []
      GameData::Ability.each { |a| out << a.id.to_s }
      out.sort
    end

    def caps_map
      {
        "max_level"         => GameData::GrowthRate.max_level,   # == Settings::MAXIMUM_LEVEL
        "iv_stat_limit"     => Pokemon::IV_STAT_LIMIT,
        "ev_limit"          => Pokemon::EV_LIMIT,
        "ev_stat_limit"     => Pokemon::EV_STAT_LIMIT,
        "no_vitamin_ev_cap" => !!Settings::NO_VITAMIN_EV_CAP
      }
    end

    # --- assembly + write ------------------------------------------------------

    def build_document
      species = {}
      GameData::Species.each { |sp| species[sp.id.to_s] = species_entry(sp) }
      moves = {}
      GameData::Move.each { |mv| moves[mv.id.to_s] = move_entry(mv) }
      items = {}
      GameData::Item.each { |it| items[it.id.to_s] = item_entry(it) }

      {
        :schema_version => SCHEMA_VERSION,
        :generated_at   => stamp,
        :caps           => caps_map,
        :natures        => natures_map,
        :growth_rates   => growth_rates_map,
        :types          => type_matrix,
        :abilities      => abilities_list,
        :items          => items,
        :moves          => moves,
        :species        => species
      }
    end

    # -> counts hash (write failures raise, surfaced by run_with_feedback).
    def run
      doc  = build_document
      path = File.expand_path(OUT_PATH)
      dir  = File.dirname(path)
      Dir.mkdir(dir) unless File.directory?(dir)   # server/data (server/ already exists)
      File.open(path, "w") { |f| f.write(PEMK::WorldExport.pretty(doc, 0) + "\n") }
      { :species => doc[:species].size, :moves => doc[:moves].size, :items => doc[:items].size }
    end

    def run_with_feedback
      c = run
      pbMessage(_INTL("Battle data export OK ->\nserver/data/battle_data.json\n\n{1} species/forms, {2} moves, {3} items.",
                      c[:species], c[:moves], c[:items]))
    rescue StandardError => e
      PEMK.log("battle-data: export failed #{e.class}: #{e.message}")
      pbMessage(_INTL("Battle data export FAILED:\n{1}: {2}", e.class.to_s, e.message))
    end

    def stamp
      Time.now.strftime("%Y-%m-%dT%H:%M:%S")
    rescue StandardError
      ""
    end
  end
end

if defined?(MenuHandlers)
  MenuHandlers.add(:debug_menu, :pemk_export_battle_data, {
    "name"        => _INTL("PEMK: Export Battle Data (Layer D)"),
    "parent"      => :main,
    "description" => _INTL("Write server/data/battle_data.json (species stats/learnsets, moves, items, type chart, natures, caps) for the server-side battle model."),
    "always_show" => false,
    "effect"      => proc {
      PEMK::BattleDataExport.run_with_feedback
      next
    }
  })
end
