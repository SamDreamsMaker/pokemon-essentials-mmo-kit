require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Badge authority B0 (docs/BADGE-AUTHORITY-DESIGN.md): the world export says what gives
# each badge. A badge set at the own level of a trainer battle's win branch names that
# battle's trainers (the demo's Brock gives badge 0 so); one set anywhere else names none;
# a set the export cannot read is listed as unknown.
class WorldExportBadgesPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters, :indent)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    c = ->(code, params, indent = 0) { Cmd.new(code, params, indent) }
    gym = Ev.new(3, 6, 5, [Page.new(nil, [
      c.(111, [12, %q{TrainerBattle.start(:LEADER_Brock, "Brock")}]),
      c.(101, ["You've earned the Boulder Badge."], 1),
      c.(355, ["$stats.set_time_to_badge(0)"], 1),
      c.(655, ["$player.badges[0] = true"], 1),
      c.(411, [], 0),
      c.(355, ["$player.badges[7] = true"], 1),        # the loss's side: no win gives it
      c.(412, [], 0),
      c.(111, [12, "$player.badges[2] == true"]),      # a test, not a set
      c.(412, [], 0),
      c.(0, [])
    ])])
    pair = Ev.new(4, 1, 1, [Page.new(nil, [
      c.(111, [12, %q{TrainerBattle.start(:LEADER_A, "A", :LEADER_B, "B", 1)}]),
      c.(355, ["$Trainer.badges[4]=true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    npc = Ev.new(5, 2, 2, [Page.new(nil, [c.(355, ["$player.badges[1] = true"]),
                                          c.(355, [%q{pbMessage("$player.badges[12] = true") # $player.badges[13] = true}]),
                                          c.(0, [])]),
                           Page.new(nil, [c.(355, ["$player.badges[n] = true"]), c.(0, [])])])
    # the loss's branch of a negated call is no win
    lost = Ev.new(6, 3, 3, [Page.new(nil, [
      c.(111, [12, %q{!TrainerBattle.start(:LEADER_C, "C")}]),
      c.(355, ["pbPlayer.badges[5] = true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    # a battle that pays nothing: no prize, no claim to prove its win
    free = Ev.new(7, 4, 4, [Page.new(nil, [
      c.(355, [%q{setBattleRule("noMoney")}]),
      c.(111, [12, %q{TrainerBattle.start(:LEADER_D, "D")}]),
      c.(355, ["$player.badges[6] = true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    # fought alone (no partner joins), two badges set on one line
    alone = Ev.new(8, 5, 5, [Page.new(nil, [
      c.(355, [%q{setBattleRule("noPartner")}]),
      c.(111, [12, %q{TrainerBattle.start(:LEADER_E, "E")}]),
      c.(355, ["$player.badges[8] = true; $player.badges[9] = true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    # a literal set then one the export cannot read, on one line; two writes chained; all at once
    mixed = Ev.new(9, 6, 6, [Page.new(nil, [c.(355, ["$player.badges[10] = true; $player.badges[k] = true"]),
                                            c.(355, ["$player.badges[14]=$player.badges[15]=true"]),
                                            c.(355, ["$player.badges.fill(true)"]), c.(0, [])])])
    # a double battle: the client asks no seed for it
    double = Ev.new(10, 7, 7, [Page.new(nil, [
      c.(355, [%q{setBattleRule("double", "canLose")}]),
      c.(111, [12, %q{TrainerBattle.start(:LEADER_F, "F")}]),
      c.(355, ["$player.badges[11] = true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    # a set, and one its comment names
    noted = Ev.new(11, 8, 8, [Page.new(nil, [c.(355, ["$player.badges[16] = true # not $player.badges[17] = true"]),
                                             c.(0, [])])])
    print PEMK::WorldExport.badge_sources([[10, gym], [11, pair], [12, npc], [13, lost], [14, free], [15, alone],
                                           [16, mixed], [17, double], [18, noted]]).inspect
  RUBY

  def test_what_gives_each_badge
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    list = got[:list]
    assert_equal({ badge: 0, map: 10, event: 3, page: 0, trainers: [["LEADER_Brock", "Brock", 0]], call: 0 }, list[0])
    assert_equal({ badge: 7, map: 10, event: 3, page: 0 }, list[1], "on the loss's side: no battle gives it")
    assert_equal({ badge: 4, map: 11, event: 4, page: 0, trainers: [["LEADER_A", "A", 0], ["LEADER_B", "B", 1]], call: 0 },
                 list[2], "a double battle: either leader's win")
    assert_equal({ badge: 1, map: 12, event: 5, page: 0 }, list[3], "given by talking: no battle")
    assert_equal({ badge: 5, map: 13, event: 6, page: 0 }, list[4], "a negated battle's branch is the loss's")
    assert_equal({ badge: 6, map: 14, event: 7, page: 0, trainers: [["LEADER_D", "D", 0]], call: 1, no_money: true }, list[5])
    assert_equal({ badge: 8, map: 15, event: 8, page: 0, trainers: [["LEADER_E", "E", 0]], call: 1, no_partner: true },
                 list[6])
    assert_equal({ badge: 9, map: 15, event: 8, page: 0, trainers: [["LEADER_E", "E", 0]], call: 1, no_partner: true },
                 list[7], "each set of a line")
    assert_equal({ badge: 10, map: 16, event: 9, page: 0 }, list[8])
    assert_equal({ badge: 15, map: 16, event: 9, page: 0 }, list[9], "the literal one of a chain")
    assert_equal({ badge: 11, map: 17, event: 10, page: 0, trainers: [["LEADER_F", "F", 0]], call: 1, size: "double" },
                 list[10], "a double battle's size")
    assert_equal({ badge: 16, map: 18, event: 11, page: 0 }, list[11], "not the one its comment names")
    assert_equal 12, list.size, "a test of a badge, a message or a comment naming one, is no source"
    assert_equal [{ map: 12, event: 5, page: 1, script: "$player.badges[n] = true" },
                  { map: 16, event: 9, page: 0, script: "$player.badges[10] = true; $player.badges[k] = true" },
                  { map: 16, event: 9, page: 0, script: "$player.badges[14]=$player.badges[15]=true" },
                  { map: 16, event: 9, page: 0, script: "$player.badges.fill(true)" }],
                 got[:unknown], "a write the export cannot read, even beside one it can"
  end

  # A game's own code setting a badge (a plugin, an edited script) is unknown to the
  # server; PEMK's own and the engine's debug menu are not the game's.
  CODE_RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    load ARGV[0]
    print [PEMK::WorldExport.badge_code_writes, PEMK::WorldExport.badge_sources([])[:unknown]].inspect
  RUBY

  def test_the_game_s_own_code_setting_badges
    Dir.mktmpdir do |dir|
      { "Plugins/MyGame/badges.rb" => "# $player.badges[0] = true\ndef win\n  $player.badges[2] = true\nend\n",
        "Plugins/MyGame/player.rb" => "class Player\n  def give(i)\n    @badges[i] = true\n  end\n" \
                                      "  def all = self.badges.fill(true)\n" \
                                      "  def say = pbMessage(\"$player.badges[1] = true\") # $player.badges[3] = true\nend\n",
        "Plugins/PEMK/004_Badges.rb" => "$player.badges[i] = v\n",
        "Data/Scripts/020_Debug/menu.rb" => "24.times { |i| $player.badges[i] = true }\n",
        "Data/Scripts/015_Player.rb" => "return $player.badges[1] == true\n    @badges                = [false] * 8\n" }
        .each do |path, text|
        FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
        File.write(File.join(dir, path), text)
      end
      out = IO.popen([RbConfig.ruby, "-W0", "-e", CODE_RUNNER, EXPORT], err: %i[child out], chdir: dir, &:read)
      assert $?.success?, "runner crashed:\n#{out}"
      writes, unknown = eval(out) # rubocop:disable Security/Eval
      assert_equal [{ file: "Plugins/MyGame/badges.rb", line: 3, script: "$player.badges[2] = true" },
                    { file: "Plugins/MyGame/player.rb", line: 3, script: "@badges[i] = true" },
                    { file: "Plugins/MyGame/player.rb", line: 5, script: "def all = self.badges.fill(true)" }], writes,
                   "the player's badges written by the game's code - not the new game's reset, a message or a comment"
      assert_equal writes, unknown, "listed as unknown by the export"
    end
  end

  # A partner the game's code registers joins its battles too: no seed for them.
  PARTNER_RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    load ARGV[0]
    print PEMK::WorldExport.partner_registrations([]).inspect
  RUBY

  def test_partners_the_game_s_code_registers
    Dir.mktmpdir do |dir|
      { "Plugins/MyGame/quest.rb" => "def join\n  pbRegisterPartner(:RIVAL, \"Blue\", 2)\nend\n",
        "Data/Scripts/012_Overworld.rb" => "def pbRegisterPartner(tr_type, tr_name, tr_id = 0)\nend\n" }.each do |path, text|
        FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
        File.write(File.join(dir, path), text)
      end
      out = IO.popen([RbConfig.ruby, "-W0", "-e", PARTNER_RUNNER, EXPORT], err: %i[child out], chdir: dir, &:read)
      assert $?.success?, "runner crashed:\n#{out}"
      assert_equal({ list: [["RIVAL", "Blue", 2]], computed: false }, eval(out)) # rubocop:disable Security/Eval
    end
  end
end
