# frozen_string_literal: true

# Subprocess body for autopilot_plugin_test.rb (world): the real autopilot files over
# a tiny fake map. The fake player moves like the engine's: a held arrow starts a step
# (the position changes at once), the step takes a few frames, and walls and events
# block. Checks walk_to, talk_to, the interruptions and text entry. One JSON line.

require "json"
require "tmpdir"

module PEMK
  def self.log(_m); end
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
    def update; @frame += 1; $world_hook&.call; end
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

def _INTL(s, *_a); s; end
def pbMapInterpreterRunning?; false; end

class Window_DrawableCommand
  attr_accessor :visible, :active, :index
  def initialize(*_a); @visible = true; @active = true; @index = 0; @disposed = false; end
  def update; end
  def disposed?; @disposed; end
  def dispose; @disposed = true; end
end

def pbMessageDisplay(_w, message, _l = true, _c = nil); message; end
def pbEnterText(_h, _min, _max, _init = "", _mode = 0, _pk = nil, _nf = false); :ui; end
def pbMessageFreeText(_m, _c, _p, _max, _w = 240); :ui; end

class Scene_Map; end

# The bag and the screen that picks an item from it (pbChooseItem and friends).
FakeBag = Struct.new(:pockets)
class PokemonBagScreen
  def initialize(bag); @bag = bag; end
  def pbChooseItemScreen(_proc = nil); :bag_ui; end
end

# A full-screen UI in Essentials' shape: pbStartScene / pbEndScene.
class FakeParty_Scene
  def pbStartScene(*_args); end
  def pbEndScene; end
end

class FakeTemp
  attr_accessor :in_battle, :in_menu, :message_window_showing, :player_transferring
end

# 8x6 map. '#' wall, '.' floor. An NPC (event 1) stands at (5,1).
MAP = [
  "........",
  "..#.....",
  "..#.....",
  "..#.....",
  "........",
  "........"
].freeze

Ev = Struct.new(:id, :name, :x, :y, :trigger, :character_name, :through)

class FakeMap
  attr_reader :events
  def initialize
    @events = { 1 => Ev.new(1, "Nurse", 5, 1, 0, "nurse", false),
                2 => Ev.new(2, "Door", 7, 0, 1, "door", false) }
  end
  def map_id; 5; end
  def name; "Test Town"; end
  def width; MAP[0].length; end
  def height; MAP.length; end
  def valid?(x, y); x >= 0 && x < width && y >= 0 && y < height; end
  def wall?(x, y); !valid?(x, y) || MAP[y][x] == "#"; end
  def occupied?(x, y); @events.values.any? { |e| e.x == x && e.y == y }; end
  # The bottom-right corner is tall grass.
  Tag = Struct.new(:land_wild_encounters)
  def terrain_tag(x, y); Tag.new(x >= 6 && y >= 4); end
end

class FakePlayer
  STEP = { 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1] }.freeze
  attr_accessor :x, :y, :direction
  def initialize; @x = 0; @y = 0; @direction = 2; @timer = 0; end
  def moving?; @timer.positive?; end
  def passable?(x, y, d, _strict = false)
    dx, dy = STEP[d]
    nx = x + dx
    ny = y + dy
    !$game_map.wall?(nx, ny) && !$game_map.occupied?(nx, ny)
  end
  def turn_down; @direction = 2; end
  def turn_left; @direction = 4; end
  def turn_right; @direction = 6; end
  def turn_up; @direction = 8; end
  # One engine frame: finish a step, or start one if an arrow is down.
  def update
    if moving?
      @timer -= 1
      return
    end
    d = Input.dir4
    return if d.zero?

    @direction = d
    unless passable?(@x, @y, d)
      # Walking into a door is what opens it.
      door = $game_map.events.values.find { |e| [e.x, e.y] == facing && e.trigger == 1 }
      $game_temp.player_transferring = true if door
      return
    end

    @x += STEP[d][0]
    @y += STEP[d][1]
    @timer = 6
  end
  def facing
    dx, dy = STEP[@direction]
    [@x + dx, @y + dy]
  end
end

PLUGINS = File.expand_path("../../../Plugins/PEMK", __dir__)
CHANNEL = File.join(Dir.mktmpdir("pemk_autopilot_world"), "ch")
ENV["PEMK_AUTOPILOT"] = CHANNEL
$DEBUG = true
load File.join(PLUGINS, "008_World/002_Export.rb")
%w[001_Autopilot 002_VirtualInput 003_Observe 004_Battle 005_Actions 006_World].each do |f|
  load File.join(PLUGINS, "011_Autopilot/#{f}.rb")
end
PEMK::Autopilot.define_singleton_method(:now) { Graphics.ticks / 60.0 }

$scene       = Scene_Map.new
$game_temp   = FakeTemp.new
$game_map    = FakeMap.new
$game_player = FakePlayer.new
$player      = nil
OBS = PEMK::Autopilot::Observe

# Talking: USE while facing the nurse opens her line; USE again closes it.
$world_hook = nil
def engine_frame!
  Input.update
  if OBS.current_message
    OBS.pop_message if Input.trigger?(Input::USE)
  elsif Input.trigger?(Input::USE) && !$game_player.moving?
    ev = $game_map.events.values.find { |e| [e.x, e.y] == $game_player.facing }
    OBS.push_message("Welcome to the Pokémon Center!") if ev
  else
    $game_player.update
  end
end

results = {}
def check(results, name)
  results[name] = (yield ? "ok" : "FAIL")
rescue StandardError => e
  results[name] = "ERROR #{e.class}: #{e.message}"
end

def send_cmd(line); File.binwrite(File.join(CHANNEL, "cmd.txt"), line); end

def reply
  path = File.join(CHANNEL, "resp.txt")
  return nil unless File.file?(path)

  body = File.read(path)
  File.delete(path)
  JSON.parse(body)
end

def run_until_reply(limit = 3000)
  limit.times do
    Graphics.update
    engine_frame!
    r = reply
    return r if r
  end
  nil
end

def command(line)
  send_cmd(line)
  run_until_reply
end

# Each check starts clean: a command still running from the previous one is
# aborted, and the player is put down idle.
def place(x, y)
  send_cmd("0 abort")
  run_until_reply(10)
  $game_player.x = x
  $game_player.y = y
end

check(results, "walks_around_a_wall") do
  place(0, 2)
  r = command("1 walk_to 4 2")
  r && r["ok"] && r["status"] == "arrived" && r["at"] == [4, 2] && r["steps"] >= 6   # straight is 4, the wall forces a detour
end

check(results, "a_walled_off_target_has_no_path") do
  place(0, 0)
  r = command("2 walk_to 2 2")   # a wall tile
  r && r["ok"] == false && r["status"] == "no_path"
end

check(results, "a_message_interrupts_the_walk") do
  place(0, 5)
  send_cmd("3 walk_to 7 5")
  r = nil
  200.times do |i|
    Graphics.update
    engine_frame!
    OBS.push_message("A trainer spotted you!") if i == 20
    r = reply
    break if r
  end
  OBS.pop_message
  r && r["ok"] == false && r["status"] == "interrupted" && r["detail"] == "message"
end

check(results, "talk_to_walks_faces_and_opens_the_line") do
  place(0, 5)
  r = command("4 talk_to 1")
  msg = OBS.current_message
  OBS.pop_message
  r && r["ok"] && r["message"] == "Welcome to the Pokémon Center!" && msg == r["message"] &&
    $game_player.facing == [5, 1]
end

check(results, "events_lists_the_map") do
  r = command("5 events")
  r && r["events"].first == { "id" => 1, "name" => "Nurse", "x" => 5, "y" => 1, "trigger" => 0, "visible" => true } &&
    r["events"].length == 2
end

# Nobody walks onto an NPC or a door: the answer says what to use instead.
check(results, "walk_to_an_event_tile_explains") do
  place(0, 5)
  r = command("5b walk_to 5 1")
  r && r["ok"] == false && r["status"] == "no_path" && r["detail"].include?("talk_to/enter 1")
end

# A door opens when walked into; the arrow must come up the moment it does, or the
# player walks on in the next map.
check(results, "enter_bumps_a_door_and_lets_go") do
  place(4, 4)
  r = command("5c enter 2")
  held = PEMK::Autopilot::VInput.held_names
  $game_temp.player_transferring = false
  r && r["ok"] && r["started"] == "transfer" && [$game_player.x, $game_player.y] == [7, 1] && held.empty?
end

check(results, "text_waits_for_type") do
  got = nil
  answered = nil
  $world_hook = lambda do
    next unless PEMK::Autopilot::TextEntry.awaiting && answered.nil?

    answered = true
    send_cmd("6 type Red Blue")
  end
  got = pbEnterText("Your name?", 1, 7, "")
  $world_hook = nil
  r = reply
  got == "Red Blu" && r && r["ok"] && r["answered"] == "Your name?"   # clipped to 7
end

check(results, "text_can_be_queued_before_the_prompt") do
  r = command("7 type hunter2")
  got = pbMessageFreeText("Enter your password:", "", true, 64)
  logged = OBS.log.map { |e| e["text"] }
  r["queued"] && got == "hunter2" && logged.include?("Enter your password:") && !logged.include?("hunter2")
end

check(results, "screens_are_tracked") do
  s = FakeParty_Scene.new
  s.pbStartScene([], "Choose a Pokémon.")
  open = command("9 state")["screens"]
  s.pbEndScene
  closed = command("10 state")["screens"]
  open == ["FakeParty_Scene"] && closed == []
end

# dismiss must hand over at anything taps cannot or must not answer.
check(results, "what_stops_a_dismiss") do
  acts = PEMK::Autopilot::Actions
  before = acts.needs_the_agent
  PEMK::Autopilot::Observe.screen_open("FakeParty_Scene")
  screen = acts.needs_the_agent
  PEMK::Autopilot::Observe.push_message("Trade request sent to Bob...")
  line_over_it = acts.needs_the_agent
  PEMK::Autopilot::Observe.pop_message
  PEMK::Autopilot::Observe.screen_closed("FakeParty_Scene")
  PEMK::Autopilot::TextEntry.instance_variable_set(:@awaiting, { "prompt" => "Your name?" })
  text = acts.needs_the_agent
  PEMK::Autopilot::TextEntry.instance_variable_set(:@awaiting, nil)
  before.nil? && screen == "screen" && line_over_it.nil? && text == "text"
end

# The pause menu stays open under the line it shows and closes once it is read:
# dismiss reads the line and does not stop at the menu's screen on the way out.
check(results, "dismiss_reads_a_line_shown_over_a_screen") do
  place(0, 5)
  obs = PEMK::Autopilot::Observe
  obs.screen_open("PokemonPauseMenu_Scene")
  obs.push_message("Trade request sent to Bob...")
  read_at = nil
  $world_hook = lambda do
    read_at ||= Graphics.frame_count if obs.current_message.nil?
    obs.screen_closed("PokemonPauseMenu_Scene") if read_at && Graphics.frame_count > read_at + 2
  end
  r = command("20 dismiss")
  $world_hook = nil
  r && r["ok"] && r["stopped"].nil? && r["presses"] == 1 && obs.screens.empty?
end

# A screen left open with nothing on it still hands over, after the quiet moment.
check(results, "dismiss_stops_at_a_screen_that_stays") do
  place(0, 5)
  obs = PEMK::Autopilot::Observe
  obs.screen_open("FakeParty_Scene")
  r = command("21 dismiss")
  obs.screen_closed("FakeParty_Scene")
  r && r["ok"] && r["stopped"] == "screen" && r["presses"].zero?
end

# The fossil reviver asks for a fossil from the bag: pick answers, filtered like the
# bag would be, without driving the bag UI.
check(results, "pick_answers_an_item_choice") do
  bag = FakeBag.new([nil, [[:POTION, 3], [:HELIXFOSSIL, 1]], [[:FOSSILIZEDBIRD, 1]]])
  screen = PokemonBagScreen.new(bag)
  fossil = ->(item) { item.to_s.include?("FOSSIL") }
  command("11 pick helixfossil")
  queued = screen.pbChooseItemScreen(fossil)
  refused = nil
  $world_hook = lambda do
    next unless PEMK::Autopilot::ItemChoice.awaiting && refused.nil?

    refused = :sent
    send_cmd("12 pick POTION")   # not a fossil: refused, the choice stays open
  end
  cancel_sent = false
  # The choice's own loop runs the frames, as it does in the game; this thread only
  # reads the replies (two threads running frames would race on the channel).
  waiting = Thread.new { screen.pbChooseItemScreen(fossil) }
  deadline = Time.now + 5
  until !waiting.alive? || Time.now > deadline
    sleep 0.001
    r = reply
    if r && r["id"] == "12"
      refused = r
      send_cmd("13 pick cancel") unless cancel_sent
      cancel_sent = true
    end
  end
  $world_hook = nil
  got = waiting.value
  queued == :HELIXFOSSIL && refused.is_a?(Hash) && refused["ok"] == false &&
    refused["allowed"] == %w[HELIXFOSSIL FOSSILIZEDBIRD] && got.nil?
end

check(results, "grass_lists_where_wild_battles_start") do
  r = command("22 grass")
  r && r["ok"] && r["tiles"].sort == [[6, 4], [6, 5], [7, 4], [7, 5]]
end

# A wild battle cuts a walk short: walk_to keeps off the grass when it can.
check(results, "walk_to_keeps_off_the_grass_when_it_can") do
  place(4, 5)
  seen = []
  $world_hook = -> { seen << [$game_player.x, $game_player.y] }
  r = command("23 walk_to 7 3")
  $world_hook = nil
  r && r["ok"] && r["status"] == "arrived" && seen.none? { |x, y| x >= 6 && y >= 4 }
end

check(results, "walk_to_goes_through_grass_when_it_must") do
  place(4, 5)
  r = command("24 walk_to 7 5")   # both ways in are grass
  r && r["ok"] && r["status"] == "arrived" && [$game_player.x, $game_player.y] == [7, 5]
end

check(results, "setters_refuse_before_a_game_is_loaded") do
  r = command("8 heal")
  r && r["ok"] == false
end

# Where the server denies debug mode (PEMK::DebugLock, 003_Game), the game's own text
# entry runs: the autopilot could not answer it.
module PEMK
  module DebugLock
    @allowed = true
    def self.autopilot_allowed?; @allowed; end
    def self.allowed=(value); @allowed = value; end
  end
end

check(results, "a_denied_autopilot_leaves_text_entry_to_the_game") do
  PEMK::DebugLock.allowed = false
  got = [pbEnterText("Your name?", 1, 7, ""), pbMessageFreeText("Hi", "", false, 10),
         PokemonBagScreen.new(FakeBag.new([nil, [[:POTION, 1]]])).pbChooseItemScreen(nil)]
  PEMK::DebugLock.allowed = true
  got == %i[ui ui bag_ui] && PEMK::Autopilot::TextEntry.awaiting.nil? && PEMK::Autopilot::ItemChoice.awaiting.nil?
end

puts JSON.generate(results)
