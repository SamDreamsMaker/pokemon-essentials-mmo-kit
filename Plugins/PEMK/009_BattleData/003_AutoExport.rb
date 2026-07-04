#===============================================================================
# PEMK :: ServerDataExport  (client side — transparent auto-regeneration of the
# server-side data exports)
#-------------------------------------------------------------------------------
# TRANSPARENCY PRINCIPLE: the developer edits maps / grass encounter zones / PBS in
# RPG Maker + PBS *normally*; the server-authority layer must be INVISIBLE. So the two
# server exports — world.json (Layer A/B: maps, passability, warps, encounters) and
# battle_data.json (Layer D: species/moves/items/types/natures/caps) — regenerate
# AUTOMATICALLY at boot whenever their source data is newer than the export (i.e. right
# after an edit + recompile). No F9, ever.
#
# WHEN: just before the title screen (pbCallTitle), in $DEBUG only. By then the boot has
# run Compiler.main (recompiled changed data) and Game.initialize (loaded GameData +
# $data_tilesets) — the exact fully-loaded state the manual exporters need. A player
# build ($DEBUG false, no PBS/maps) never runs this and never writes server data.
#
# HOW IT DECIDES: pure mtime staleness — an export is regenerated iff it's MISSING or any
# of its source files is newer. This is self-healing (a deleted export comes back), needs
# no compile-flag plumbing, and over-regenerating is harmless. Fully rescue-guarded: a
# failed export logs and is skipped — it must NEVER break boot. The manual
# "PEMK: Export ..." debug tools remain as an explicit fallback.
#===============================================================================
module PEMK
  module ServerDataExport
    module_function

    def run_if_needed
      return unless $DEBUG

      export_world  if stale?(world_path,  world_sources)
      export_battle if stale?(battle_path, battle_sources)
    rescue StandardError => e
      (PEMK.log("auto-export: gate error #{e.class}: #{e.message}") rescue nil)
    end

    # A target is stale if it is missing, or any EXISTING source is newer than it.
    def stale?(target, sources)
      t = File.exist?(target) ? File.mtime(target).to_i : -1
      return true if t < 0

      sources.any? { |s| File.exist?(s) && File.mtime(s).to_i > t }
    rescue StandardError
      false   # a stat error must not trigger a needless (or boot-breaking) export
    end

    def export_world
      $data_tilesets ||= (load_data("Data/Tilesets.rxdata") rescue nil)   # normally set by Game.initialize
      c = PEMK::WorldExport.run
      (PEMK.log("auto-export: world.json regenerated #{c.inspect}") rescue nil)
    rescue StandardError => e
      (PEMK.log("auto-export: world.json FAILED #{e.class}: #{e.message}") rescue nil)
    end

    def export_battle
      c = PEMK::BattleDataExport.run
      (PEMK.log("auto-export: battle_data.json regenerated #{c.inspect}") rescue nil)
    rescue StandardError => e
      (PEMK.log("auto-export: battle_data.json FAILED #{e.class}: #{e.message}") rescue nil)
    end

    def world_path;  File.expand_path(PEMK::WorldExport::OUT_PATH);      end
    def battle_path; File.expand_path(PEMK::BattleDataExport::OUT_PATH); end

    # world.json derives from the maps + their stitching/metadata + tilesets. A missing
    # source name simply doesn't contribute (stale? checks File.exist?).
    def world_sources
      ["Data/MapInfos.rxdata", "Data/map_connections.dat", "Data/map_metadata.dat",
       "Data/Tilesets.rxdata"] + (Dir.glob("Data/Map[0-9]*.rxdata") rescue [])
    end

    # battle_data.json derives from the compiled GameData .dat files it walks.
    def battle_sources
      %w[species moves abilities items types].map { |n| "Data/#{n}.dat" }
    end
  end
end

# Regenerate stale server exports just before the title screen (see header). Guarded so
# it only aliases once, and only when pbCallTitle exists (it does at boot — 999_Main is
# loaded before PluginManager.runPlugins runs this — but the guard keeps the file safe to
# load in a headless test harness too).
if defined?(pbCallTitle) && !defined?(pemk_orig_pbCallTitle)
  alias pemk_orig_pbCallTitle pbCallTitle
  def pbCallTitle
    (PEMK::ServerDataExport.run_if_needed rescue nil)
    pemk_orig_pbCallTitle
  end
end
