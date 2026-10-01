require "minitest/autorun"
require "socket"
require "timeout"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# PEMK_CLIENT_DEBUG over the wire: login and auth tell the client whether debug mode
# stays off (deny by default), the boot log says the level, and a client that cannot
# keep it off is named - not refused (an older client plays on).
class ServerClientDebugTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(extra = {})
    env = ENV.to_h.reject { |k, _| k.start_with?("PEMK_") && !%w[PEMK_BIND PEMK_PORT].include?(k) }.merge(extra)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
  end

  def logs
    @seen ||= []
    @seen << @logs.pop until @logs.empty?
    @seen
  end

  def wait_log(pattern, timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if logs.any? { |l| l.match?(pattern) }
      return false if Time.now > deadline

      sleep 0.05
    end
  end

  def send_env(s, e) = s.write(W.encode_split(e))

  def recv_type(s, *types)
    Timeout.timeout(5) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        env = W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
        return env if types.include?(env[:type])
      end
    end
  end

  def login(email, caps: %w[debug_lock])
    s = TCPSocket.new("127.0.0.1", @server.port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    [s, recv_type(s, :login_ok, :login_err)]
  end

  def test_deny_by_default
    start_server
    assert wait_log(/client debug = deny \(debug mode stays off on the clients/)
    s, lo = login("deny@t.co")
    assert_equal [:login_ok, "deny"], lo.values_at(:type, :client_debug)
    send_env(s, { type: :auth, token: lo[:token], caps: %w[debug_lock], resume: true })
    assert_equal "deny", recv_type(s, :auth_ok, :auth_err)[:client_debug], "a resume says it again"
    refute logs.any? { |l| l.include?("keeps debug mode") }
    _, old = login("old@t.co", caps: [])
    assert_equal :login_ok, old[:type], "an older client is not refused"
    assert wait_log(/account #{old[:account_id]}'s client keeps debug mode \(no debug_lock/)
  end

  def test_autopilot_and_allow
    start_server({ "PEMK_CLIENT_DEBUG" => "autopilot", "PEMK_ALLOW_PICKUP_RESET" => "on" })
    assert wait_log(/WARNING client debug = autopilot/)
    assert wait_log(/PEMK_ALLOW_PICKUP_RESET does nothing - its tool is in the debug menu/)
    assert_equal "autopilot", login("ap@t.co")[1][:client_debug]
    @server.stop
    @seen = nil
    @logs.clear
    start_server({ "PEMK_CLIENT_DEBUG" => " Allow ", "PEMK_ALLOW_PICKUP_RESET" => "on" })
    assert wait_log(/WARNING client debug = allow/)
    refute logs.any? { |l| l.include?("PEMK_ALLOW_PICKUP_RESET does nothing") }
    _, lo = login("allow@t.co", caps: [])
    assert_equal "allow", lo[:client_debug]
    refute wait_log(/keeps debug mode/, 0.5), "allow: nothing to keep off"
  end
end
