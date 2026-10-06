require "minitest/autorun"
require "rbconfig"
require "tmpdir"

# Field gates (world export): an obstacle is listed only when it is nothing but its gate -
# a page that asks for nothing, every page shows a character, blocks, stands still and runs
# only the gate (its own shake at most), and nothing else on the map moves it; a headbutt
# tree is a wall; the falls rows mark a waterfall, not its crest.
class WorldExportFieldGatesPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings
      PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false
      BADGE_FOR_CUT = 1
      BADGE_FOR_ROCKSMASH = 2
      BADGE_FOR_STRENGTH = 3
      BADGE_FOR_WATERFALL = 6
    end
    module GameData; module Trainer; def self.each; end; end; end
    def load_data(_path); []; end
    load ARGV[0]

    Cmd     = Struct.new(:code, :parameters, :indent)
    Graphic = Struct.new(:character_name, :tile_id)
    Cond    = Struct.new(:switch1_valid, :switch2_valid, :variable_valid, :self_switch_valid)
    Page    = Struct.new(:graphic, :through, :move_type, :list, :condition)
    Ev      = Struct.new(:id, :name, :x, :y, :pages)
    Map     = Struct.new(:events, :tileset_id, :data, :width, :height)
    Route   = Struct.new(:list)
    MC      = Struct.new(:code, :parameters)
    c = ->(code, *params) { Cmd.new(code, params, 0) }
    free  = Cond.new(false, false, false, false)
    sw    = Cond.new(true, false, false, false)
    self_a = Cond.new(false, false, false, true)
    sw2    = Cond.new(false, true, false, false)
    var    = Cond.new(false, false, true, false)
    page  = ->(graphic, list, through: false, move_type: 0, cond: free) { Page.new(graphic, through, move_type, list, cond) }
    tree  = Graphic.new("Object tree 1", 0)
    shake = ->(*codes) { [c.(209, 0, Route.new(codes.map { |k| MC.new(k, []) } + [MC.new(0, [])])), c.(509, MC.new(codes.first, []))] }
    gate  = shake.(16, 15, 19) + [c.(111, 12, "pbCut"), c.(355, "pbSmashThisEvent"), c.(412), c.(0)]
    cut   = ->(id, x, list = gate, **kw) { Ev.new(id, "CutTree", x, 2, [page.(tree, list, **kw)]) }
    events = {
      1 => cut.(1, 5),                                                                                    # judged
      2 => Ev.new(2, "CutTree", 6, 2, [page.(tree, gate), page.(Graphic.new("", 0), [c.(0)], cond: self_a)]),   # gone for good: no
      3 => Ev.new(3, "SmashRock", 7, 2, [page.(Graphic.new("Object rock", 0),
                                               [c.(111, 12, "pbRockSmash"), c.(355, "pbSmashThisEvent"),
                                                c.(355, "pbRockSmashRandomEncounter"), c.(412), c.(0)])]),   # judged
      4 => Ev.new(4, "StrengthBoulder", 8, 2, [page.(Graphic.new("Object boulder", 0), [c.(355, "pbPushThisBoulder"), c.(0)])]), # moved by 9: no
      5 => Ev.new(5, "HeadbuttTree", 9, 2, [page.(Graphic.new("Object tree 2", 0), [c.(355, "pbHeadbutt"), c.(0)])]),            # wall
      6 => cut.(6, 10, gate + [c.(121, 5, 5, 0)]),                                                       # more than its gate: no
      7 => cut.(7, 11, through: true),                                                                   # through: no
      10 => cut.(10, 12, move_type: 1),                                                                  # wanders: no
      11 => Ev.new(11, "CutTree", 13, 2, [page.(Graphic.new("", 7), gate)]),                              # a tile graphic: no
      12 => cut.(12, 14),                                                                                # erased by 19's script: no
      13 => cut.(13, 15),                                                                                # reached by 19's script: no
      14 => cut.(14, 16),                                                                                # placed by 9 (202): no
      15 => cut.(15, 17, [c.(111, 12, "pbCut && $game_switches[5]"), c.(355, "pbSmashThisEvent"), c.(412), c.(0)]), # another branch: no
      16 => cut.(16, 18, cond: sw),                                                                      # only while a switch: no
      22 => cut.(22, 23, cond: sw2),                                                                     # or a second one: no
      23 => cut.(23, 24, cond: var),                                                                     # or a variable: no
      24 => cut.(24, 25, cond: self_a),                                                                  # or a self switch: no
      17 => Ev.new(17, "CutTree", 19, 2, [page.(tree, gate), page.(tree, gate, cond: self_a)]),         # two gate pages: judged
      18 => cut.(18, 20, shake.(16, 1) + gate.drop(2)),                                                 # its route moves it: no
      20 => cut.(20, 21, shake.(16, 37) + gate.drop(2)),                                                # its route goes through: no
      21 => cut.(21, 22, [c.(209, 0, Route.new([MC.new(16, []), MC.new(0, [])])), c.(509, MC.new(41, []))] + gate.drop(2)), # a new graphic: no
      9 => Ev.new(9, "Mover", 0, 0, [page.(Graphic.new("", 0), [c.(209, 4, Route.new([])), c.(202, 14, 0, 1, 1, 2), c.(0)])]),
      19 => Ev.new(19, "Script", 0, 1, [page.(Graphic.new("", 0), [c.(355, "$game_map.events[12].erase"), c.(655, "get_character(13).moveto(1, 1)"), c.(0)])])
    }
    obstacles, walls = PEMK::WorldExport.map_gates(Map.new(events))
    print [obstacles, walls, PEMK::WorldExport.field_gates[:badges]].inspect
  RUBY

  def test_only_a_bare_gate_is_judged
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    obstacles, walls, badges = eval(out) # rubocop:disable Security/Eval
    assert_equal [{ event: 1, x: 5, y: 2, move: "CUT" }, { event: 3, x: 7, y: 2, move: "ROCKSMASH" },
                  { event: 17, x: 19, y: 2, move: "CUT" }], obstacles
    assert_equal [{ event: 5, x: 9, y: 2 }], walls
    assert_equal({ cut: 1, rocksmash: 2, strength: 3, waterfall: 6 }, badges)
  end

  # The moves half follows the engine's functions: one asking for a Pokemon is true, one
  # that does not is false, one a script of the game redefines is nil; no badge setting,
  # no field gates.
  MOVES = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings
      PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false
      BADGE_FOR_CUT = 1
      BADGE_FOR_ROCKSMASH = 2
      BADGE_FOR_STRENGTH = 3
      BADGE_FOR_WATERFALL = 6
    end
    module GameData; module Trainer; def self.each; end; end; end
    def load_data(_path); []; end
    load ARGV[0]
    Dir.chdir(ARGV[1])
    require "fileutils"
    FileUtils.mkdir_p("Data/Scripts/012_Overworld")
    FileUtils.mkdir_p("Plugins/Mine")
    File.write("Data/Scripts/012_Overworld/004_Overworld_FieldMoves.rb", <<~SRC)
      def pbCut
        movefinder = $player.get_pokemon_with_move(:CUT)
      end
      def pbRockSmash
        true
      end
      def pbStrength
        movefinder = $player.get_pokemon_with_move(:STRENGTH)
      end
      def pbWaterfall
        movefinder = $player.get_pokemon_with_move(:WATERFALL)
      end
    SRC
    File.write("Plugins/Mine/strength.rb", "def pbStrength\n  true\nend\n")
    gates = PEMK::WorldExport.field_gates
    Settings.send(:remove_const, :BADGE_FOR_WATERFALL)
    print [gates[:moves], PEMK::WorldExport.field_gates].inspect
  RUBY

  def test_the_moves_half_and_no_badge_setting
    out = Dir.mktmpdir("pemk_gates") { |dir| IO.popen([RbConfig.ruby, "-W0", "-e", MOVES, EXPORT, dir], err: %i[child out], &:read) }
    assert $?.success?, "runner crashed:\n#{out}"
    moves, none = eval(out) # rubocop:disable Security/Eval
    assert_equal({ cut: true, rocksmash: false, strength: nil, waterfall: true }, moves)
    assert_nil none
  end

  FALLS = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    def load_data(_path); []; end
    load ARGV[0]

    Tag = Struct.new(:id_number, :ignore_passability, :bridge, :waterfall)
    TAGS = { 1 => Tag.new(13, false, false, true), 2 => Tag.new(14, false, false, false), 3 => Tag.new(7, false, false, false) }
    module PEMK; module WorldExport; def self.terrain_of(_tags, tid) = TAGS[tid]; end; end
    class Grid
      def initialize(cells) = @cells = cells
      def [](x, y, z) = (z.zero? ? @cells[[x, y]] : 0)
    end
    Tileset = Struct.new(:terrain_tags)
    $data_tilesets = { 1 => Tileset.new(:tags) }
    Map = Struct.new(:events, :tileset_id, :data, :width, :height)
    # a fall (tag 1) at (1,0) and (1,1), its crest (tag 2) at (1,2), water at (0,0)
    map = Map.new({}, 1, Grid.new({ [1, 0] => 1, [1, 1] => 1, [1, 2] => 2, [0, 0] => 3 }), 3, 3)
    print [PEMK::WorldExport.map_falls(map), PEMK::WorldExport.map_falls(Map.new({}, 1, Grid.new({}), 2, 2))].inspect
  RUBY

  def test_the_falls_rows
    out = IO.popen([RbConfig.ruby, "-W0", "-e", FALLS, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    rows, none = eval(out) # rubocop:disable Security/Eval
    assert_equal [".f.", ".f.", "..."], rows, "the fall, not its crest"
    assert_nil none
  end
end
