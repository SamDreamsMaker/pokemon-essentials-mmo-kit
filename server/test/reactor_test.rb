require "minitest/autorun"
require "socket"
require "timeout"

lib   = File.expand_path("../lib", __dir__)
proto = File.expand_path("../../protocol", __dir__)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk_wire"
require "pemk/reactor"

# Integration test for the IO.select reactor over real localhost sockets: frame
# delivery, a ping/pong round-trip (server -> client write path), rejection of
# legacy whole-Marshal frames on the host path, and two frames coalesced in one
# write being sliced apart.
class ReactorTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @received = Queue.new
    @reactor  = PEMK::Reactor.new(host: "127.0.0.1", port: 0, on_frame: method(:handle))
    @reactor.start
    @thread = Thread.new { @reactor.run }
    @thread.abort_on_exception = true
  end

  def teardown
    @reactor.stop
    @thread&.join(3)
  end

  def handle(conn, payload)
    dec = W.decode_envelope(payload, false)
    @received << dec
    @reactor.send_frame(conn, W.encode_split({ type: :pong, t: dec[:env][:t] })) if dec && dec[:env][:type] == :ping
  end

  def read_frame(sock, timeout = 3)
    Timeout.timeout(timeout) do
      len = sock.read(4).unpack1("N")
      W.decode_envelope(sock.read(len), false)
    end
  end

  def test_ping_pong_roundtrip
    sock = TCPSocket.new("127.0.0.1", @reactor.port)
    sock.write(W.encode_split({ type: :ping, t: 7 }))
    got = Timeout.timeout(3) { @received.pop }
    assert_equal :ping, got[:env][:type]
    pong = read_frame(sock)
    assert_equal :pong, pong[:env][:type]
    assert_equal 7, pong[:env][:t]
    sock.close
  end

  def test_legacy_frame_rejected_on_host_path
    sock = TCPSocket.new("127.0.0.1", @reactor.port)
    sock.write(W.encode({ type: :ping })) # legacy whole-Marshal
    assert_nil Timeout.timeout(3) { @received.pop }
    sock.close
  end

  def test_two_frames_in_one_write
    sock = TCPSocket.new("127.0.0.1", @reactor.port)
    sock.write(W.encode_split({ type: :ping, t: 1 }) + W.encode_split({ type: :ping, t: 2 }))
    a = Timeout.timeout(3) { @received.pop }
    b = Timeout.timeout(3) { @received.pop }
    assert_equal [1, 2], [a[:env][:t], b[:env][:t]].sort
    sock.close
  end
end
