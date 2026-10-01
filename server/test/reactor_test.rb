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
    @last_conn = conn
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

  def connected
    sock = TCPSocket.new("127.0.0.1", @reactor.port)
    sock.write(W.encode_split({ type: :hello }))
    Timeout.timeout(3) { @received.pop }
    sock
  end

  def eof?(sock)
    Timeout.timeout(3) { sock.read(1).nil? }
  end

  # A replaced session is told why, then closed: what is queued goes out first.
  def test_finish_writes_what_is_queued_then_closes
    sock = connected
    @reactor.post do
      @reactor.send_frame(@last_conn, W.encode_split({ type: :bye }))
      @reactor.finish(@last_conn)
    end
    assert_equal :bye, read_frame(sock)[:env][:type]
    assert eof?(sock)
    sock.close
  end

  # A socket marked closing with nothing left to write closed only on its next read
  # or write; a silent one stayed open. The sweep closes it now.
  def test_the_sweep_closes_a_silent_closing_socket
    sock = connected
    @reactor.post { @last_conn.closing = true }
    @reactor.post { @reactor.send(:sweep_idle, Process.clock_gettime(Process::CLOCK_MONOTONIC)) }
    assert eof?(sock)
    sock.close
  end

  # A closing socket whose output never drains (a dead link, its send buffer full) is
  # closed once CLOSE_GRACE has passed - its map would keep it until then.
  def test_the_sweep_closes_a_closing_socket_that_never_drains
    sock = connected
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    open = Queue.new
    @reactor.post do
      @last_conn.closing = true
      @last_conn.outbuf << "stuck".b                  # what a dead link never takes
      @reactor.send(:sweep_idle, now)                  # the grace starts
      open << @reactor.instance_variable_get(:@conns).key?(@last_conn.io)
      @reactor.send(:sweep_idle, now + PEMK::Reactor::CLOSE_GRACE + 1)
      open << @reactor.instance_variable_get(:@conns).key?(@last_conn.io)
    end
    assert_equal [true, false], [Timeout.timeout(3) { open.pop }, Timeout.timeout(3) { open.pop }]
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
