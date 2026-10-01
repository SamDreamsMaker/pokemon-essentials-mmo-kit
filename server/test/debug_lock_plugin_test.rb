require "minitest/autorun"
require "rbconfig"

# Debug mode stays off where the server says (PEMK_CLIENT_DEBUG): the client's lock, run
# in a subprocess - it traces Ruby's own $DEBUG.
class DebugLockPluginTest < Minitest::Test
  LOCK = File.expand_path("../../Plugins/PEMK/003_Game/007_DebugLock.rb", __dir__)

  RUNNER = <<~'RUBY'
    $stdout.sync = true
    real_err = $stderr.dup
    $stderr.reopen(File::NULL)   # $DEBUG on: Ruby reports every exception raised
    begin
      $logs = []
      $notices = []
      def _INTL(s); s; end
      module PEMK
        def self.log(m); $logs << m; end
        module NetStatus; def self.notify(key, msg); $notices << [key, msg]; end; end
      end
      load ARGV[0]
      lock = PEMK::DebugLock
      out = {}
      $DEBUG = true                  # a debug launch
      lock.adopt(nil)
      lock.adopt("allow")
      lock.adopt("junk")
      out[:untold] = [lock.locked?, $DEBUG]
      lock.adopt("autopilot")
      out[:autopilot] = [lock.locked?, lock.autopilot_allowed?, $DEBUG, $notices.size]
      eval("$DEBUG = true")          # an event's script line
      out[:event_write] = $DEBUG
      $-d = true
      out[:dash_d] = [$DEBUG, $-d]
      lock.adopt("deny")
      out[:deny_wins] = lock.autopilot_allowed?
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

  def test_debug_mode_stays_off_once_the_server_says
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, LOCK], err: %i[child out], &:read)
    assert $?.success?, "lock runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval
    assert_equal [false, true], got[:untold], "a server that says nothing, or allow: debug mode as launched"
    assert_equal [true, true, false, 1], got[:autopilot], "autopilot: off at once, the autopilot obeyed, told once"
    assert_equal false, got[:event_write], "an event's write is undone as it happens"
    assert_equal [false, false], got[:dash_d]
    assert_equal false, got[:deny_wins], "deny: the autopilot only reads"
    assert_equal [true, false], got[:sticky], "nothing unlocks it"
    assert_equal false, got[:thread]
    assert_equal false, got[:tick], "the frame's check backs the trace"
    assert_equal [[[:debug_off, "Debug mode is off on this server."]], 1], got[:told], "told once"
  end
end
