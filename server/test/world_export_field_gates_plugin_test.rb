require "minitest/autorun"
require "rbconfig"

# Field gates (world export): an obstacle is listed only when it is nothing but its gate -
# every page shows it, blocks, stands still and runs only the gate, and nothing else on the
# map moves it; a headbutt tree is a wall; the falls rows mark a waterfall, not its crest.
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
    Page    = Struct.new(:graphic, :through, :move_type, :list)
    Ev      = Struct.new(:id, :name, :x, :y, :pages)
    Map     = Struct.new(:events, :tileset_id, :data, :width, :height)
    c = ->(code, *params) { Cmd.new(code, params, 0) }
    tree = Graphic.new("Object tree 1", 0)
    gate = [c.(209, 0, :shake), c.(509, :step), c.(111, 12, "pbCut"), c.(355, "pbSmashThisEvent"), c.(412), c.(0)]
    events = {
      1 => Ev.new(1, "CutTree", 5, 2, [Page.new(tree, false, 0, gate)]),                                   # judged
      2 => Ev.new(2, "CutTree", 6, 2, [Page.new(tree, false, 0, gate), Page.new(Graphic.new("", 0), false, 0, [c.(0)])]), # gone for good: no
      3 => Ev.new(3, "SmashRock", 7, 2, [Page.new(Graphic.new("Object rock", 0), false, 0,
                                                   [c.(111, 12, "pbRockSmash"), c.(355, "pbSmashThisEvent"),
                                                    c.(355, "pbRockSmashRandomEncounter"), c.(412), c.(0)])]),       # judged
      4 => Ev.new(4, "StrengthBoulder", 8, 2, [Page.new(Graphic.new("Object boulder", 0), false, 0,
                                                         [c.(355, "pbPushThisBoulder"), c.(0)])]),                    # moved by event 9: no
      5 => Ev.new(5, "HeadbuttTree", 9, 2, [Page.new(Graphic.new("Object tree 2", 0), false, 0, [c.(355, "pbHeadbutt"), c.(0)])]), # wall
      6 => Ev.new(6, "CutTree", 4, 4, [Page.new(tree, false, 0, gate + [c.(121, 5, 5, 0)])]),              # more than its gate: no
      7 => Ev.new(7, "CutTree", 3, 4, [Page.new(tree, true, 0, gate)]),                                      # through: no
      9 => Ev.new(9, "Mover", 0, 0, [Page.new(Graphic.new("", 0), false, 0, [c.(209, 4, :route), c.(0)])])
    }
    obstacles, walls = PEMK::WorldExport.map_gates(Map.new(events))
    print [obstacles, walls, PEMK::WorldExport.field_gates[:badges]].inspect
  RUBY

  def test_only_a_bare_gate_is_judged
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    obstacles, walls, badges = eval(out) # rubocop:disable Security/Eval
    assert_equal [{ event: 1, x: 5, y: 2, move: "CUT" }, { event: 3, x: 7, y: 2, move: "ROCKSMASH" }], obstacles
    assert_equal [{ event: 5, x: 9, y: 2 }], walls
    assert_equal({ cut: 1, rocksmash: 2, strength: 3, waterfall: 6 }, badges)
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
