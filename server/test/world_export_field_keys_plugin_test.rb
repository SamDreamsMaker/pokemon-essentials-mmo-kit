require "minitest/autorun"
require "rbconfig"
require "tmpdir"

# Mode keys (world export): the badge Surf and Dive need, as the game's Settings say,
# and the scripts that start a swim by themselves - an event's, a common event's, the
# game's own code - the engine's Surf and Dive aside.
class WorldExportFieldKeysPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings
      PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false
      FIELD_MOVES_COUNT_BADGES = true
      BADGE_FOR_SURF = 4
      BADGE_FOR_DIVE = 7
    end
    module GameData; module Trainer; def self.each; end; end; end
    CE = Struct.new(:id, :list)
    $common_events = []
    def load_data(_path); $common_events; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters, :indent)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    c = ->(code, params, indent = 0) { Cmd.new(code, params, indent) }
    boat = Ev.new(9, 1, 1, [Page.new(nil, [c.(101, ["All aboard!"]),
                                           c.(355, ["$PokemonGlobal.surfing = true"]),
                                           c.(655, ["pbUpdateVehicle"]),
                                           c.(0, [])])])
    talk = Ev.new(10, 2, 2, [Page.new(nil, [c.(355, [%q{pbMessage("$PokemonGlobal.surfing = true")}]),   # a message names it
                                           c.(355, ["$PokemonGlobal.surfing = false"]),                 # the end of a swim
                                           c.(355, ["x = $PokemonGlobal.surfing"]),                     # a read
                                           c.(0, [])]),
                             Page.new(nil, [c.(355, ["pbStartSurfing # the ferry"]), c.(0, [])])])
    $common_events = [CE.new(4, [c.(355, ["$PokemonGlobal.diving ||= true"]), c.(0, [])])]
    dir = ARGV[1]
    Dir.chdir(dir)
    Dir.mkdir("Plugins"); Dir.mkdir("Plugins/MyGame"); Dir.mkdir("Plugins/PEMK")
    Dir.mkdir("Data"); Dir.mkdir("Data/Scripts"); Dir.mkdir("Data/Scripts/012_Overworld")
    File.write("Plugins/MyGame/ferry.rb", "def ferry\n  $PokemonGlobal.surfing = true\nend\n# $PokemonGlobal.surfing = true\n")
    File.write("Plugins/MyGame/override.rb", "alias ferry_surf pbStartSurfing\ndef pbStartSurfing\n  ferry_surf\nend\n")   # definitions start no swim
    File.write("Plugins/PEMK/own.rb", "$PokemonGlobal.surfing = true\n")   # PEMK's own (the snap-back): not a source
    File.write("Data/Scripts/012_Overworld/004_Overworld_FieldMoves.rb",
               "def pbSurf\n  movefinder = $player.get_pokemon_with_move(:SURF)\n  pbStartSurfing\nend\n" \
               "def pbStartSurfing\n  $PokemonGlobal.surfing = true\nend\n" \
               "def pbDive\n  pbMessage('deep')\nend\n" \
               "def pbSurfacing\n  movefinder = $player.get_pokemon_with_move(:DIVE)\nend\n")   # a game that dropped Dive's Pokemon
    File.write("Data/Scripts/012_Overworld/009_Custom.rb", "pbStartSurfing if $game_switches[9]\n")
    keys = PEMK::WorldExport.field_keys([[3, boat], [5, talk]])
    print keys.inspect
  RUBY

  def test_the_keys_and_what_starts_a_swim_by_itself
    out = Dir.mktmpdir("pemk_keys") { |dir| IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT, dir], err: %i[child out], &:read) }
    assert $?.success?, "runner crashed:\n#{out}"
    keys = eval(out) # rubocop:disable Security/Eval
    assert_equal true, keys[:count_badges]
    assert_equal [4, 7], keys.values_at(:surf, :dive)
    assert_equal [{ map: 3, event: 9, page: 0, script: "$PokemonGlobal.surfing = true" },
                  { map: 5, event: 10, page: 1, script: "pbStartSurfing # the ferry" },
                  { common_event: 4, script: "$PokemonGlobal.diving ||= true" },
                  { file: "Data/Scripts/012_Overworld/009_Custom.rb", line: 1, script: "pbStartSurfing if $game_switches[9]" },
                  { file: "Plugins/MyGame/ferry.rb", line: 2, script: "$PokemonGlobal.surfing = true" }],
                 keys[:mode_sources], "a message, a read, an end of a swim, a comment, the engine's own and PEMK's are none"
    assert_equal [true, false], keys.values_at(:surf_move, :dive_move), "Surf still asks for a Pokemon, Dive no longer"
  end

  # A script of the game redefining pbSurf: its rule is unknown (nil); no engine file: nil.
  REDEFINED = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings
      PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false
      BADGE_FOR_SURF = 4
      BADGE_FOR_DIVE = 7
    end
    module GameData; module Trainer; def self.each; end; end; end
    def load_data(_path); []; end
    load ARGV[0]
    Dir.chdir(ARGV[1])
    Dir.mkdir("Plugins"); Dir.mkdir("Plugins/MyGame"); Dir.mkdir("Data"); Dir.mkdir("Data/Scripts")
    before = PEMK::WorldExport.field_keys([]).values_at(:surf_move, :dive_move)
    Dir.mkdir("Data/Scripts/012_Overworld")
    File.write("Data/Scripts/012_Overworld/004_Overworld_FieldMoves.rb",
               "def pbSurf\n  $player.get_pokemon_with_move(:SURF)\nend\ndef pbDive\n  $player.get_pokemon_with_move(:DIVE)\nend\n" \
               "def pbSurfacing\n  $player.get_pokemon_with_move(:DIVE)\nend\n")
    File.write("Plugins/MyGame/surfboard.rb", "def pbSurf\n  pbStartSurfing if $bag.has?(:SURFBOARD)\nend\n")
    surfboard = PEMK::WorldExport.field_keys([]).values_at(:surf_move, :dive_move)
    File.delete("Plugins/MyGame/surfboard.rb")
    File.write("Plugins/MyGame/anywater.rb", "class Trainer\n  def get_pokemon_with_move(move)\n    pokemon_party.find { |p| p.types.include?(:WATER) }\n  end\nend\n")
    anywater = PEMK::WorldExport.field_keys([]).values_at(:surf_move, :dive_move)
    File.delete("Plugins/MyGame/anywater.rb")
    File.write("Plugins/MyGame/001_Trainer.rb", "class Trainer\n  def get_pokemon_with_move(move)\n    nil\n  end\nend\n")   # the engine file's namesake
    print [before, surfboard, anywater, PEMK::WorldExport.field_keys([]).values_at(:surf_move, :dive_move)].inspect
  RUBY

  def test_a_redefined_rule_is_unknown
    out = Dir.mktmpdir("pemk_keys") { |dir| IO.popen([RbConfig.ruby, "-W0", "-e", REDEFINED, EXPORT, dir], err: %i[child out], &:read) }
    assert $?.success?, "runner crashed:\n#{out}"
    assert_equal [[nil, nil], [nil, true], [nil, nil], [nil, nil]], eval(out), # rubocop:disable Security/Eval
                 "no engine file: unknown; a surfboard's pbSurf: Surf unknown, Dive as the engine; any Water type surfs: both unknown; a plugin named like the engine's file: unknown"
  end

  # This repository's own engine and plugins: the stock rule, PEMK's aliases unseen.
  REAL = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings
      PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false
      BADGE_FOR_SURF = 4
      BADGE_FOR_DIVE = 7
    end
    module GameData; module Trainer; def self.each; end; end; end
    def load_data(_path); []; end
    load ARGV[0]
    Dir.chdir(ARGV[1])
    print PEMK::WorldExport.field_keys([]).values_at(:surf_move, :dive_move).inspect
  RUBY

  def test_this_repository_still_asks_for_the_move
    root = File.expand_path("../..", __dir__)
    skip "no engine scripts here (a copy of server/ and Plugins/ alone)" unless Dir.exist?(File.join(root, "Data", "Scripts"))
    out = IO.popen([RbConfig.ruby, "-W0", "-e", REAL, EXPORT, root], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    assert_equal "[true, true]", out.strip
  end

  NO_KEYS = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end   # a game with no field move badges
    module GameData; module Trainer; def self.each; end; end; end
    def load_data(_path); []; end
    load ARGV[0]
    print PEMK::WorldExport.field_keys([]).inspect
  RUBY

  def test_a_game_without_the_settings_exports_no_keys
    out = IO.popen([RbConfig.ruby, "-W0", "-e", NO_KEYS, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    assert_equal "nil", out.strip
  end
end
