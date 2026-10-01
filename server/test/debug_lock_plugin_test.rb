require "minitest/autorun"
require "rbconfig"

# Debug mode stays off where the server says (PEMK_CLIENT_DEBUG): the client's lock, run
# in a subprocess - it traces Ruby's own $DEBUG.
class DebugLockPluginTest < Minitest::Test
  LOCK = File.expand_path("../../Plugins/PEMK/003_Game/007_DebugLock.rb", __dir__)

  # ARGV: the lock's file, then the first level the server says
  RUNNER = <<~'RUBY'
    $stdout.sync = true
    real_err = $stderr.dup
    $stderr.reopen(File::NULL)   # $DEBUG on: Ruby reports every exception raised
    begin
      $logs = []
      $notices = []
      $disarms = 0
      def _INTL(s); s; end
      module PEMK
        def self.log(m); $logs << m; end
        module NetStatus; def self.notify(key, msg); $notices << [key, msg]; end; end
        module Autopilot
          def self.active?; true; end
          def self.disarm; $disarms += 1; end
        end
      end
      load ARGV[0]
      lock = PEMK::DebugLock
      out = {}
      $DEBUG = true                  # a debug launch
      lock.adopt(nil)
      lock.adopt("allow")
      lock.adopt("junk")
      out[:untold] = [lock.locked?, $DEBUG, $disarms]
      lock.adopt(ARGV[1])
      out[:first] = [lock.locked?, lock.autopilot_allowed?, $DEBUG, $notices.size, $disarms]
      eval("$DEBUG = true")          # an event's script line
      out[:event_write] = $DEBUG
      $-d = true
      out[:dash_d] = [$DEBUG, $-d]
      lock.adopt("deny")
      lock.adopt("deny")
      out[:deny] = [lock.autopilot_allowed?, $disarms]
      lock.adopt("allow")
      lock.adopt(nil)
      lock.adopt("autopilot")
      out[:sticky] = [lock.locked?, lock.autopilot_allowed?]
      Thread.new { $DEBUG = true }.join
      out[:thread] = $DEBUG
      untrace_var(:$DEBUG)           # a write no trace saw: the frame's check
      $DEBUG = true
      lock.tick
      out[:tick] = $DEBUG
      out[:told] = [$notices, $logs.grep(/turned off/).size]
      print out.inspect
    rescue Exception => e # rubocop:disable Lint/RescueException
      real_err.puts "CRASH #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      exit 1
    end
  RUBY

  def run_lock(first)
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, LOCK, first], err: %i[child out], &:read)
    assert $?.success?, "lock runner crashed:\n#{out}"
    eval(out) # rubocop:disable Security/Eval
  end

  def common(got)
    assert_equal [false, true, 0], got[:untold], "a server that says nothing, or allow: debug mode as launched"
    assert_equal false, got[:event_write], "an event's write is undone as it happens"
    assert_equal [false, false], got[:dash_d]
    assert_equal [true, false], got[:sticky], "nothing unlocks it"
    assert_equal false, got[:thread]
    assert_equal false, got[:tick], "the frame's check backs the trace"
  end

  # The autotest's level: off at once, the autopilot obeyed, the player not told (a
  # message box would wait for a key after each relaunch); a later deny disarms it once.
  def test_autopilot_then_deny
    got = run_lock("autopilot")
    common(got)
    assert_equal [true, true, false, 0, 0], got[:first]
    assert_equal [false, 1], got[:deny], "deny wins: the autopilot disarmed, once"
    assert_equal [[], 1], got[:told], "logged once, no notice"
  end

  # A server that denies it: off at once, the autopilot disarmed, the player told once.
  def test_deny_first
    got = run_lock("deny")
    common(got)
    assert_equal [true, false, false, 1, 1], got[:first]
    assert_equal [false, 1], got[:deny], "denied again: nothing to disarm again"
    assert_equal [[[:debug_off, "Debug mode is off on this server."]], 1], got[:told], "told once"
  end
end
