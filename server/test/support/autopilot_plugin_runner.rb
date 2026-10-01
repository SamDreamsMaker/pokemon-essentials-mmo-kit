# frozen_string_literal: true

# Subprocess body for autopilot_plugin_test.rb: load the real autopilot plugin files
# under minimal engine stubs, drive them frame by frame the way the engine does
# (Graphics.update, then Input.update, then the scene reads the keys), and print one
# JSON line of named checks.

require "json"
require "tmpdir"

# --- minimal engine surface -------------------------------------------------
module PEMK
  @log = []
  def self.log(m); @log << m.to_s; end
  def self.logs; @log; end
  def self.instance; "ap1"; end
  def self.client; nil; end
  module Auth
    def self.logged_in?; false; end
    def self.account_id; nil; end
  end
end

module Graphics
  @frame = 0
  @ticks = 0
  @shots = []
  class << self
    attr_reader :shots, :ticks
    attr_writer :frame_count   # Game.load restores it from the save's play time
    def frame_count; @frame_count || @frame; end
    # A frame also updates the open menus, as their loops do in the engine.
    def update; @frame += 1; @ticks += 1; $live_windows.each { |w| w.update unless w.disposed? || w.idle }; end
    def screenshot(path); @shots << path; File.binwrite(path, "PNG"); end
  end
end

# The real Input module exposes C, B, A... plus the aliases Essentials adds.
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
  def initialize(commands)
    super(0, 0, 32, 32)
    @commands = commands
  end
end

def pbMessageDisplay(_msgwindow, message, _letterbyletter = true, _command_proc = nil)
  yield if block_given?
  message
end

PLUGINS = File.expand_path("../../../Plugins/PEMK", __dir__)
# Nested and missing: the plugin has to create the parents itself.
CHANNEL = File.join(Dir.mktmpdir("pemk_autopilot"), "autopilot", "ap1")
ENV["PEMK_AUTOPILOT"] = CHANNEL
$DEBUG = true

load File.join(PLUGINS, "008_World/002_Export.rb")   # the kit's JSON writer
load File.join(PLUGINS, "011_Autopilot/001_Autopilot.rb")
load File.join(PLUGINS, "011_Autopilot/002_VirtualInput.rb")
load File.join(PLUGINS, "011_Autopilot/003_Observe.rb")

# Deadlines run on the wall clock; here the clock is the stub's frames at 60 a second,
# so a check can "wait" a minute in a blink and stay deterministic.
PEMK::Autopilot.define_singleton_method(:now) { Graphics.ticks / 60.0 }

$scene = nil
$game_temp = nil
$game_map = nil
$game_player = nil
$player = nil

results = {}

def check(results, name)
  results[name] = (yield ? "ok" : "FAIL")
rescue StandardError => e
  results[name] = "ERROR #{e.class}: #{e.message}"
end

# One engine frame: the per-frame poll, then the key state advances.
def frame!
  Graphics.update
  Input.update
end

def send_cmd(line)
  File.binwrite(File.join(CHANNEL, "cmd.txt"), line)
end

def reply
  path = File.join(CHANNEL, "resp.txt")
  return nil unless File.file?(path)

  body = File.read(path)
  File.delete(path)
  JSON.parse(body)
end

# Run frames until a reply lands (or give up), the way the driver waits.
def await(limit = 200)
  limit.times do
    frame!
    r = reply
    return r if r
  end
  nil
end

USE = Input::USE

check(results, "boots_on_in_debug") { PEMK::Autopilot.active? && PEMK::Autopilot.dir == CHANNEL }

check(results, "ping_answers_with_the_id") do
  send_cmd("7 ping")
  r = await
  r && r["id"] == "7" && r["ok"] == true && r["frame"].is_a?(Integer)
end

check(results, "unknown_verb_is_an_error_not_a_crash") do
  send_cmd("8 fly")
  r = await
  r && r["ok"] == false && r["error"].include?("fly")
end

# A writer caught between creating the file and writing it: nothing raises, and the
# command is read once it is there.
check(results, "an_empty_command_file_waits_for_its_line") do
  errors = PEMK.logs.size
  send_cmd("")
  3.times { frame! }
  waited = File.file?(File.join(CHANNEL, "cmd.txt")) && reply.nil?
  send_cmd("9e ping")
  r = await
  waited && r && r["id"] == "9e" && r["ok"] == true && PEMK.logs.size == errors
end

# From WSL the driver's rename can land as the game deletes the file, and the
# delete is refused: the command runs once, not again on the following frames.
$refuse_cmd_delete = false
class << File
  alias_method :runner_orig_delete, :delete
  def delete(*paths)
    raise Errno::EACCES, paths.first.to_s if $refuse_cmd_delete && paths.first.to_s.end_with?("cmd.txt")

    runner_orig_delete(*paths)
  end
end

check(results, "a_command_whose_file_will_not_go_runs_once") do
  $refuse_cmd_delete = true
  send_cmd("9f ping")
  first = await
  again = nil
  5.times { frame!; again ||= reply }
  $refuse_cmd_delete = false
  send_cmd("9g ping")
  nxt = await
  first && first["id"] == "9f" && again.nil? && nxt && nxt["id"] == "9g"
end

check(results, "unknown_key_is_refused") do
  send_cmd("9 press JUMP")
  r = await
  r && r["ok"] == false
end

# A tap: trigger on the first step only, press while down, release on the step after.
check(results, "a_press_is_one_trigger_then_a_release") do
  seen = []
  send_cmd("10 press USE 2")
  r = nil
  30.times do
    frame!
    seen << [Input.trigger?(USE), Input.press?(USE), Input.release?(USE)]
    r ||= reply
    break if r
  end
  triggers = seen.count { |t, _, _| t }
  presses  = seen.count { |_, p, _| p }
  releases = seen.count { |_, _, rel| rel }
  r && r["ok"] && triggers == 1 && presses == 2 && releases == 1 && seen.first == [true, true, false]
end

# The reply comes after the release, so the next "state" sees the effect.
check(results, "a_press_answers_after_the_release") do
  send_cmd("11 press USE 1")
  frames = 0
  r = nil
  20.times do
    frame!
    frames += 1
    r = reply
    break if r
  end
  r && r["ok"] && !Input.press?(USE) && frames >= 2
end

check(results, "hold_and_release_move_the_player") do
  send_cmd("12 hold DOWN")
  await
  frame!
  moving = Input.dir4 == 2 && Input.dir8 == 2 && Input.press?(Input::DOWN)
  send_cmd("13 release DOWN")
  await
  frame!
  moving && Input.dir4 == 0 && !Input.press?(Input::DOWN)
end

# The most recent direction wins, like a real keyboard.
check(results, "the_newest_direction_wins") do
  send_cmd("14 hold UP")
  await
  3.times { frame! }
  send_cmd("15 hold LEFT")
  await
  frame!
  newest = Input.dir4 == 4
  send_cmd("16 release all")
  await
  frame!
  newest && Input.dir4 == 0
end

check(results, "a_held_arrow_repeats") do
  send_cmd("17 hold DOWN")
  await
  hits = 0
  40.times do
    frame!
    hits += 1 if Input.repeat?(Input::DOWN)
  end
  send_cmd("18 release all")
  await
  # steps 2..41 were watched: repeats fire once the key has been down past 15 steps,
  # then every 4 steps - at 19, 23, 27, 31, 35 and 39
  hits == 6
end

check(results, "wait_counts_frames") do
  send_cmd("19 wait 30")
  start = Graphics.frame_count
  r = await(100)
  r && r["ok"] && Graphics.frame_count - start >= 30
end

# Loading a save restores Graphics.frame_count to the saved play time. A wait (or any
# job deadline) measured on it would jump by hours and fail at once, which is exactly
# what the first in-game run did.
check(results, "a_restored_play_time_does_not_break_a_wait") do
  send_cmd("30 wait 30")
  2.times { frame! }
  Graphics.frame_count = 48_000
  r = await(100)
  Graphics.frame_count = nil
  r && r["ok"] == true
end

# A long command must not blind the agent: state still answers, and abort frees it.
check(results, "state_and_abort_cut_into_a_running_command") do
  send_cmd("40 wait 100000")
  frame!
  send_cmd("41 state")
  seen = await(5)
  send_cmd("42 abort")
  frame!
  aborted = reply   # the abort's own answer overwrote the wait's; read the file state
  seen && seen["id"] == "41" && seen["ok"] && aborted && aborted["id"] == "42" && aborted["aborted"] == "40"
end

check(results, "screenshot_lands_in_the_channel") do
  send_cmd("20 screenshot")
  r = await
  r && r["ok"] && File.dirname(r["path"]) == CHANNEL && File.file?(r["path"])
end

# A path with spaces survives the one-line protocol.
check(results, "screenshot_path_may_contain_spaces") do
  send_cmd("21 screenshot my shot.png")
  r = await
  r && r["ok"] && r["path"] == File.join(CHANNEL, "my shot.png")
end

check(results, "state_reports_the_message_and_menus") do
  inside = nil
  pbMessageDisplay(nil, "\\c[1]Hello \\PN!\\wtnp[10]") do
    menu = Window_CommandPokemon.new(%w[Yes No])
    menu.index = 1
    send_cmd("22 state")
    inside = await
    menu.dispose
  end
  send_cmd("23 state")
  after = await
  inside && inside["message"] == "Hello !" &&
    inside["menus"] == [{ "class" => "Window_CommandPokemon", "commands" => %w[Yes No], "index" => 1 }] &&
    after["message"].nil? && after["menus"].empty? && after["instance"] == "ap1"
end

check(results, "a_stuck_command_times_out") do
  send_cmd("24 press USE 600")
  # Input.update never runs, so the key never comes up: only frames pass.
  r = nil
  limit = (PEMK::Autopilot::JOB_SECONDS * 60).to_i + 5   # a minute of stub frames, and a bit
  limit.times do
    Graphics.update
    r = reply
    break if r
  end
  PEMK::Autopilot::VInput.release_all
  3.times { frame! }
  r && r["ok"] == false && r["error"].include?("timeout")
end

# Where the server denies debug mode (PEMK::DebugLock, 003_Game), the autopilot only reads.
module PEMK
  module DebugLock
    @allowed = true
    def self.autopilot_allowed?; @allowed; end
    def self.allowed=(value); @allowed = value; end
  end
end

check(results, "a_denied_autopilot_only_reads") do
  PEMK::DebugLock.allowed = false
  send_cmd("30 press USE")
  refused = await
  send_cmd("31 state")
  state = await
  send_cmd("32 wait 1")
  waited = await
  PEMK::DebugLock.allowed = true
  send_cmd("33 press USE")
  pressed = await
  3.times { frame! }
  refused && refused["ok"] == false && refused["error"].include?("locked by the server") &&
    state && state["ok"] == true && state["debug"] == true && waited && waited["ok"] == true &&
    pressed && pressed["ok"] == true
end

puts JSON.generate(results)
