# frozen_string_literal: true

# Subprocess body for autopilot_plugin_test.rb (battles): the real autopilot files
# over a fake Battle::Scene whose decision points behave like the engine's - an
# "original" UI method that records it ran, and blocks that accept or refuse the
# way Battle#pbFightMenu / pbPartyScreen / pbItemMenu do. Prints one JSON line.

require "json"
require "tmpdir"

module PEMK
  @log = []
  def self.log(m); @log << m.to_s; end
  def self.instance; "ap1"; end
  def self.client; nil; end
  module Auth
    def self.logged_in?; false; end
    def self.account_id; nil; end
  end
end

module Graphics
  @frame = 0
  class << self
    def frame_count; @frame; end
    def ticks; @frame; end
    def update; @frame += 1; $live_windows.each { |w| w.update unless w.disposed? || w.idle }; end
    def screenshot(path); File.binwrite(path, "PNG"); end
  end
end

module Input
  DOWN = 2; LEFT = 4; RIGHT = 6; UP = 8
  A = 11; B = 12; C = 13; X = 14; Y = 15; Z = 16; L = 17; R = 18
  SHIFT = 21; CTRL = 22; ALT = 23; F5 = 25; F6 = 26; F7 = 27; F8 = 28; F9 = 29
  USE = C; BACK = B; ACTION = A; JUMPUP = X; JUMPDOWN = Y; SPECIAL = Z; AUX1 = L; AUX2 = R
  class << self
    def update; end
    def trigger?(_k); false; end
    def press?(_k); false; end
    def repeat?(_k); false; end
    def release?(_k); false; end
    def dir4; 0; end
    def dir8; 0; end
  end
end

def _INTL(s, *_args); s; end

$live_windows = []

class Window_DrawableCommand
  attr_accessor :visible, :active, :index, :idle   # idle: its loop is not running
  def initialize(*_args); @visible = true; @active = true; @index = 0; @disposed = false; $live_windows << self; end
  def update; end
  def disposed?; @disposed; end
  def dispose; @disposed = true; end
end

class Window_CommandPokemon < Window_DrawableCommand
  attr_reader :commands
  def initialize(commands); super(0, 0, 32, 32); @commands = commands; end
end

def pbMessageDisplay(_w, message, _lbl = true, _cp = nil); message; end

$event_running = false
def pbMapInterpreterRunning?; $event_running; end

# Like the engine's: a window that only waits for USE.
def pbTopRightWindow(_text, _scene = nil)
  200.times do
    Graphics.update
    Input.update
    return :closed if Input.trigger?(Input::USE)
  end
  :still_open
end

module GameData
  module Type
    def self.exists?(_t); false; end
  end
  module Item
    Data = Struct.new(:id, :battle_use)
    def self.try_get(sym); { POKEBALL: Data.new(:POKEBALL, 4), POTION: Data.new(:POTION, 1) }[sym]; end
  end
end

class FakeBag
  def has?(item); item == :POKEBALL; end
end
$bag = FakeBag.new

Move    = Struct.new(:id, :name, :pp, :total_pp, :type, :power)
Mon     = Struct.new(:name, :species, :level, :hp, :totalhp) do
  def able?; hp.positive?; end
end
Battler = Struct.new(:name, :species, :level, :hp, :totalhp, :status, :moves, :pokemonIndex) do
  def fainted?; hp <= 0; end
end

class FakeBattle
  attr_accessor :turnCount, :refuse
  attr_reader :battlers

  def initialize
    @turnCount = 0
    @refuse = []   # move indices whose registration fails
    @battlers = [
      Battler.new("Bulbasaur", :BULBASAUR, 5, 19, 19, :NONE,
                  [Move.new(:TACKLE, "Tackle", 35, 35, :NORMAL), Move.new(:GROWL, "Growl", 40, 40, :NORMAL)], 0),
      Battler.new("Pidgey", :PIDGEY, 3, 12, 14, :NONE, [Move.new(:TACKLE, "Tackle", 35, 35, :NORMAL)], 0)
    ]
    @party = [Mon.new("Bulbasaur", :BULBASAUR, 5, 19, 19), Mon.new("Omanyte", :OMANYTE, 1, 0, 11),
              Mon.new("Dracozolt", :DRACOZOLT, 1, 12, 12)]
  end

  def wildBattle?; true; end
  def trainerBattle?; false; end
  def pbParty(_idx); @party; end
  def pbFindBattler(i, _idx); i.zero? ? @battlers[0] : nil; end
  def pbCanChooseMove?(_idx, _i, _msg); true; end
  def allOtherSideBattlers(_idx); [Struct.new(:index).new(1)]; end
end

module Battle; end

# The engine's UI methods, standing in: each records that the UI ran.
class Battle::Scene
  attr_reader :ui_calls
  def initialize; @ui_calls = []; @updates = 0; end
  def pbStartBattle(battle); @battle = battle; end
  def pbEndBattle(_result); @ui_calls << :end; end
  def pbUpdate(_cw = nil)
    @updates += 1
    raise "no decision arrived" if @updates > 20_000
    Graphics.update
    Input.update
  end
  def pbCommandMenu(_i, _f); @ui_calls << :command; :ui; end
  def pbFightMenu(_i, _m = false); @ui_calls << :fight; yield(0); end
  def pbChooseTarget(_i, _t, _v = nil); @ui_calls << :target; :ui; end
  def pbPartyScreen(_i, _c = false, _m = 0); @ui_calls << :party; end
  def pbItemMenu(_i, _f); @ui_calls << :item; end
  def pbShowCommands(_msg, _cmds, _d); @ui_calls << :commands; :ui; end
  def pbForgetMove(_p, _m); @ui_calls << :forget; :ui; end
  def pbNameEntry(_h, _p); @ui_calls << :name; :ui; end
  def pbShowPokedex(_s); @ui_calls << :pokedex; end
  def pbDisplayMessage(_msg, _brief = false); @ui_calls << :message; end
  def pbDisplayPausedMessage(_msg); @ui_calls << :paused; end
  def pbCreateTargetTexts(_i, _t); [nil, "Pidgey"]; end
  def pbFirstTarget(_i, _t); 1; end
end

PLUGINS = File.expand_path("../../../Plugins/PEMK", __dir__)
CHANNEL = File.join(Dir.mktmpdir("pemk_autopilot_battle"), "ch")
ENV["PEMK_AUTOPILOT"] = CHANNEL
$DEBUG = true
load File.join(PLUGINS, "008_World/002_Export.rb")
%w[001_Autopilot 002_VirtualInput 003_Observe 004_Battle 005_Actions].each do |f|
  load File.join(PLUGINS, "011_Autopilot/#{f}.rb")
end
PEMK::Autopilot.define_singleton_method(:now) { Graphics.ticks / 60.0 }

$scene = nil
$game_temp = nil
$game_map = nil
$game_player = nil
$player = nil
CTL = PEMK::Autopilot::BattleControl

results = {}
def check(results, name)
  results[name] = (yield ? "ok" : "FAIL")
rescue StandardError => e
  results[name] = "ERROR #{e.class}: #{e.message}"
end

def frame!; Graphics.update; Input.update; end
def send_cmd(line); File.binwrite(File.join(CHANNEL, "cmd.txt"), line); end

def reply
  path = File.join(CHANNEL, "resp.txt")
  return nil unless File.file?(path)

  body = File.read(path)
  File.delete(path)
  JSON.parse(body)
end

def await(limit = 300)
  limit.times do
    frame!
    r = reply
    return r if r
  end
  nil
end

def command(line)
  send_cmd(line)
  await
end

# A decide still waiting for its next question answers when the battle ends: end
# the previous one and drop that answer, so each check starts clean.
def fresh_scene
  CTL.detach
  3.times { frame! }
  path = File.join(CHANNEL, "resp.txt")
  File.delete(path) if File.file?(path)
  scene = Battle::Scene.new
  battle = FakeBattle.new
  scene.pbStartBattle(battle)
  [scene, battle]
end

check(results, "keys_mode_runs_the_engine_ui_and_reports_the_point") do
  scene, = fresh_scene
  seen = nil
  scene.define_singleton_method(:pemk_ap_orig_pbCommandMenu) do |_i, _f|
    seen = CTL.awaiting && CTL.awaiting["kind"]
    :ui
  end
  r = scene.pbCommandMenu(0, true)
  r == :ui && seen == "command" && CTL.awaiting.nil?
end

check(results, "the_mode_switches_and_is_reported") do
  r = command("1 battle mode agent")
  r["ok"] && r["mode"] == "agent" && command("2 battle mode flying")["ok"] == false
end

check(results, "decide_needs_a_pending_point") do
  r = command("3 decide fight")
  r["ok"] == false && r["error"].include?("no battle decision")
end

check(results, "agent_command_by_label") do
  scene, = fresh_scene
  send_cmd("4 decide fight")
  scene.pbCommandMenu(0, true) == 0 && !scene.ui_calls.include?(:command)
end

# The decide answer waits for the next question: here the fight menu.
check(results, "decide_answers_at_the_next_point") do
  scene, = fresh_scene
  send_cmd("5 decide run")
  v = scene.pbCommandMenu(0, true)
  first_reply = reply
  send_cmd("6 decide Growl")
  got = nil
  scene.pbFightMenu(0) { |i| got = i; true }
  r5 = reply
  v == 3 && first_reply.nil? && r5 && r5["id"] == "5" && r5["next"] == "fight" && got == 1
end

check(results, "a_refused_move_is_reported_and_asked_again") do
  scene, = fresh_scene
  send_cmd("7 decide 0")
  calls = []
  engine = lambda do |i|
    calls << i
    if calls.length == 1
      send_cmd("8 decide 1")   # the agent answers the second question
      false                    # the engine refuses index 0 (say, no PP left)
    else
      true
    end
  end
  scene.pbFightMenu(0) { |i| engine.call(i) }
  r7 = nil
  3.times { r7 ||= reply; frame! }
  calls == [0, 1] && r7 && r7["accepted"] == false && r7["next"] == "fight"
end

check(results, "a_move_that_does_not_exist_is_an_error") do
  scene, = fresh_scene
  answered = nil
  scene.define_singleton_method(:pbUpdate) do |_cw = nil|
    Graphics.update
    Input.update
    answered ||= reply
    CTL.mode = :keys if answered   # unblock the point after the error came back
  end
  send_cmd("9 decide Hyper Beam")
  scene.pbFightMenu(0) { |_i| true }
  CTL.mode = :agent
  answered && answered["ok"] == false && answered["error"].include?("fight")
end

check(results, "party_by_name_and_cancel") do
  scene, = fresh_scene
  send_cmd("10 decide Dracozolt")
  got = nil
  scene.pbPartyScreen(0, true) { |i, sink| got = [i, sink.respond_to?(:pbDisplay)]; true }
  send_cmd("11 decide cancel")
  called = false
  scene.pbPartyScreen(0, true) { |_i, _s| called = true; true }
  got == [2, true] && !called
end

check(results, "a_ball_goes_to_the_only_foe") do
  scene, = fresh_scene
  send_cmd("12 decide POKEBALL")
  args = nil
  scene.pbItemMenu(0, true) { |*a| args = a; true }
  args && args[0] == :POKEBALL && args[1] == 4 && args[2] == 1 && args[3] == -1
end

check(results, "an_item_not_in_the_bag_is_refused_and_logged") do
  scene, = fresh_scene
  send_cmd("13 decide POTION")
  used = false
  scene.define_singleton_method(:pbUpdate) do |_cw = nil|
    Graphics.update
    Input.update
    send_cmd("14 decide cancel") if CTL.result == false && !File.file?(File.join(CHANNEL, "cmd.txt"))
  end
  scene.pbItemMenu(0, true) { |*_a| used = true; true }
  log = PEMK::Autopilot::Observe.log.map { |e| e["text"] }
  !used && log.any? { |t| t.include?("no POTION in the bag") }
end

check(results, "prompts_names_and_forgetting_in_agent_mode") do
  scene, = fresh_scene
  send_cmd("15 decide no")
  confirm = scene.pbShowCommands("Use next Pokémon?", %w[Yes No], 1)
  send_cmd("16 decide Pip")
  name = scene.pbNameEntry("Nickname?", nil)
  mon = Struct.new(:moves).new([Move.new(:TACKLE, "Tackle", 1, 1, :NORMAL)])
  send_cmd("17 decide none")
  forget = scene.pbForgetMove(mon, :VINEWHIP)
  confirm == 1 && name == "Pip" && forget == -1
end

check(results, "auto_mode_plays_on_its_own") do
  command("18 battle mode auto")
  scene, battle = fresh_scene
  battle.refuse = [0]
  cmd = scene.pbCommandMenu(0, true)
  tried = []
  scene.pbFightMenu(0) { |i| tried << i; !battle.refuse.include?(i) }
  switch = nil
  scene.pbPartyScreen(0, false) { |i, _s| switch = i; true }   # Omanyte fainted: Dracozolt
  prompts = [scene.pbShowCommands("Use next Pokémon?", %w[Yes No], 1),
             scene.pbForgetMove(Struct.new(:moves).new([]), :X), scene.pbNameEntry("?", nil)]
  scene.pbShowPokedex(:PIDGEY)
  cmd == 0 && tried == [0, 1] && switch == 2 && prompts == [0, -1, ""] &&
    !scene.ui_calls.include?(:pokedex)
end

# The first move may be a status move: used forever, the battle would never end.
check(results, "auto_mode_uses_the_strongest_move") do
  command("18b battle mode auto")
  scene, battle = fresh_scene
  battle.battlers[0].moves = [Move.new(:GROWL, "Growl", 40, 40, :NORMAL, 0),
                              Move.new(:TACKLE, "Tackle", 35, 35, :NORMAL, 40),
                              Move.new(:VINEWHIP, "Vine Whip", 25, 25, :GRASS, 45)]
  battle.refuse = [2]
  tried = []
  scene.pbFightMenu(0) { |i| tried << i; !battle.refuse.include?(i) }
  tried == [2, 1]   # the strongest, and when it is refused the next strongest
end

check(results, "paused_messages_close_on_their_own_off_the_keys") do
  scene, = fresh_scene
  scene.pbDisplayPausedMessage("You defeated the foe!")
  logged = PEMK::Autopilot::Observe.log.last["text"] == "You defeated the foe!"
  logged && scene.ui_calls == [:message]
end

check(results, "a_stuck_turn_hands_the_keys_back") do
  scene, = fresh_scene
  answers = Array.new(CTL::MAX_ASKS_PER_TURN + 1) { scene.pbCommandMenu(0, true) }
  back = CTL.mode == :keys
  command("19 battle mode auto")
  back && answers.first == 0 && answers.last == :ui
end

check(results, "state_shows_the_battle") do
  command("20 battle mode agent")
  scene, = fresh_scene
  seen = nil
  send_cmd("21 state")
  scene.define_singleton_method(:pbUpdate) do |_cw = nil|
    Graphics.update
    Input.update
    seen ||= reply
    CTL.mode = :keys if seen
  end
  scene.pbCommandMenu(0, true)
  CTL.mode = :agent
  b = seen && seen["battle"]
  b && b["awaiting"]["kind"] == "command" && b["awaiting"]["options"] == %w[fight bag pokemon run] &&
    b["battlers"].map { |x| [x["name"], x["side"]] } == [%w[Bulbasaur player], %w[Pidgey foe]]
end

check(results, "wait_until_sees_the_battle_end") do
  scene, = fresh_scene
  send_cmd("22 wait_until decision|no_battle within 100")
  frame!
  scene.pbEndBattle(0)
  r = await
  r && r["ok"] && r["matched"] == "no_battle"
end

check(results, "wait_until_rejects_unknown_conditions") do
  r = command("23 wait_until sunrise")
  r["ok"] == false && r["error"].include?("sunrise")
end

check(results, "choose_picks_a_menu_entry_by_label") do
  menu = Window_CommandPokemon.new(["Pokémon", "Bag", "Save"])
  r = command("24 choose save")
  chose = menu.index
  menu.dispose
  r["ok"] && r["chose"] == "Save" && chose == 2
end

# Level-up stats wait for a key: with the agent or the policy playing they close on
# their own (and the gains are in the log); at the keys nobody presses for them.
check(results, "key_wait_windows_advance_off_the_keys") do
  command("25 battle mode agent")
  agent = pbTopRightWindow("Max. HP<r>+2\nAttack<r>+1")
  logged = PEMK::Autopilot::Observe.log.last["text"] == "Max. HP+2 Attack+1"
  command("26 battle mode keys")
  keys = pbTopRightWindow("Speed<r>+1")
  agent == :closed && logged && keys == :still_open
end

# A level-up opens two such windows back to back. The second needs a fresh press: a
# key still down from the first is no trigger, and that hung a real battle.
check(results, "two_key_wait_windows_in_a_row_both_close") do
  command("26b battle mode agent")
  first  = pbTopRightWindow("Max. HP<r>+2")
  second = pbTopRightWindow("Max. HP<r>21")
  command("26c battle mode keys")
  first == :closed && second == :closed
end

# A fake message box: the next queued line shows, and USE closes it.
def pump_messages!(queue)
  obs = PEMK::Autopilot::Observe
  obs.pop_message if obs.current_message && Input.trigger?(Input::USE)
  obs.push_message(queue.shift) if obs.current_message.nil? && !queue.empty?
end

check(results, "dismiss_clears_a_chain_of_lines") do
  queue = ["Hello!", "Take this Potion.", "Good luck!"]
  send_cmd("27 dismiss")
  r = nil
  300.times do
    Graphics.update
    Input.update
    pump_messages!(queue)
    r = reply
    break if r
  end
  r && r["ok"] && r["presses"] == 3 && PEMK::Autopilot::Observe.current_message.nil?
end

# The nurse: a line, a healing jingle with no line on screen (the event still runs),
# then more lines. dismiss must carry on through the gap.
check(results, "dismiss_waits_out_a_pause_inside_an_event") do
  queue = ["OK, I'll take your Pokémon.", :pause, "Thank you for waiting.", "We hope to see you again!"]
  obs = PEMK::Autopilot::Observe
  pause_left = 0
  $event_running = true
  send_cmd("27b dismiss")
  r = nil
  900.times do
    Graphics.update
    Input.update
    if obs.current_message
      obs.pop_message if Input.trigger?(Input::USE)
    elsif pause_left.positive?
      pause_left -= 1
    elsif queue.first == :pause
      queue.shift
      pause_left = 120   # two seconds of jingle
    elsif !queue.empty?
      obs.push_message(queue.shift)
    else
      $event_running = false
    end
    r = reply
    break if r
  end
  $event_running = false
  r && r["ok"] && r["presses"] == 3 && queue.empty?
end

check(results, "clean_strips_codes_but_not_words") do
  c = PEMK::Autopilot::Observe
  c.clean("\\rHello, and welcome\\wtnp[10]") == "Hello, and welcome" &&
    c.clean("\\bWould you like to rest\\c[1] your Pokémon?") == "Would you like to rest your Pokémon?" &&
    c.clean("\\wdWe hope to see you again!\\1") == "We hope to see you again!"
end

check(results, "dismiss_stops_at_a_choice") do
  PEMK::Autopilot::Observe.push_message("Do you want a Pokémon?")
  menu = Window_CommandPokemon.new(%w[Yes No])
  r = command("28 dismiss")
  menu.dispose
  PEMK::Autopilot::Observe.pop_message
  r && r["ok"] && r["stopped"] == "menu" && r["menus"].first["commands"] == %w[Yes No]
end

check(results, "wait_until_a_menu_with_an_entry") do
  send_cmd("29 wait_until menu_with 001: Bulb within 5")
  3.times { frame! }
  menu = Window_CommandPokemon.new(["001: Bulbasaur", "002: Ivysaur"])
  r = await
  menu.dispose
  r && r["ok"] && r["matched"] == "menu_with"
end

# A choice list is waiting for an answer from the moment it exists, before its loop
# has updated it once: a dismiss tapping in that frame answered "Yes" for the agent.
check(results, "a_brand_new_menu_is_already_listed") do
  menu = Window_CommandPokemon.new(%w[Yes No])
  menu.idle = true   # created, not updated yet
  listed = PEMK::Autopilot::Observe.menus.map { |m| m["commands"] }
  menu.dispose
  listed == [%w[Yes No]]
end

# The debug menu stays open behind the prompt its command opened; only the menu
# still being updated takes the keys, so only it is listed (seen in a real run).
check(results, "a_menu_left_in_the_background_is_not_listed") do
  back = Window_CommandPokemon.new(%w[Fight Run])
  back.idle = true
  5.times { frame! }   # the prompt opens later; the menu behind stopped being updated
  front = Window_CommandPokemon.new(%w[Yes No])
  r = command("31 state")
  back.dispose
  front.dispose
  r && r["menus"].map { |m| m["commands"] } == [%w[Yes No]]
end

check(results, "wait_accepts_seconds") do
  send_cmd("30 wait 1s")
  start = Graphics.ticks
  r = await(200)
  r && r["ok"] && Graphics.ticks - start >= 60
end

# Where the server denies debug mode (PEMK::DebugLock, 003_Game): disarmed at login, the
# autopilot leaves the battles, the keys and the messages to the player.
module PEMK
  module DebugLock
    @allowed = true
    def self.autopilot_allowed?; @allowed; end
    def self.allowed=(value); @allowed = value; end
  end
end

check(results, "a_disarmed_autopilot_leaves_the_game_alone") do
  ap = PEMK::Autopilot
  ap::BattleControl.mode = :auto
  ap::Actions.advance = true
  ap::VInput.hold(ap::VInput.key("USE"), nil)
  driving = ap.driving? && ap::Actions.advance? && !ap::VInput.held_names.empty? && !ap::BattleControl.at_keys?
  PEMK::DebugLock.allowed = false
  # denied: no auto-advance and the player's keys in battle, even before the disarm
  gated = !ap::Actions.advance? && ap::BattleControl.at_keys?
  # a command still running, and a channel that cannot be written to: everything is reset
  ap.instance_variable_set(:@job, -> { false })
  ap.instance_variable_set(:@job_id, "77")
  respond = ap.method(:respond)
  ap.define_singleton_method(:respond) { |*_args| raise Errno::ENOENT, "the channel is gone" }
  begin
    ap.disarm
  ensure
    ap.define_singleton_method(:respond, respond)
  end
  gated &&= ap.instance_variable_get(:@job).nil?
  after = [ap.driving?, ap::Actions.advance?, ap::BattleControl.mode, ap::VInput.held_names]
  PEMK::DebugLock.allowed = true
  after[1] = ap::Actions.advance?   # its own setting is off too, not only the gate
  driving && gated && after == [false, false, :keys, []]
end

puts JSON.generate(results)
