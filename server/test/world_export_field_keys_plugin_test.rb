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
    File.write("Plugins/PEMK/own.rb", "$PokemonGlobal.surfing = true\n")   # PEMK's own (the snap-back): not a source
    File.write("Data/Scripts/012_Overworld/004_Overworld_FieldMoves.rb", "def pbStartSurfing\n  $PokemonGlobal.surfing = true\nend\n")
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
