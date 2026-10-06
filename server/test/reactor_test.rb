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
    return @reactor.send(:close_conn, conn) if @close_on_frame
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
    open = Queue.new
    @reactor.post do
      @last_conn.outbuf << "stuck".b                  # what a dead link never takes
      def (@last_conn.io).write_nonblock(*) = :wait_writable   # and never will
      @reactor.finish(@last_conn)                      # the grace starts here
      open << @reactor.instance_variable_get(:@conns).key?(@last_conn.io)
      @reactor.send(:sweep_idle, Process.clock_gettime(Process::CLOCK_MONOTONIC) + PEMK::Reactor::CLOSE_GRACE + 1)
      open << @reactor.instance_variable_get(:@conns).key?(@last_conn.io)
    end
    assert_equal [true, false], [Timeout.timeout(3) { open.pop }, Timeout.timeout(3) { open.pop }]
    sock.close
  end

  # A frame that closes its socket (an overflow, a bad frame) takes the rest of the read
  # with it: the frames after it in the same write are never dispatched.
  def test_a_close_drops_the_rest_of_the_read
    @close_on_frame = true
    sock = TCPSocket.new("127.0.0.1", @reactor.port)
    sock.write(W.encode_split({ type: :ping, t: 1 }) + W.encode_split({ type: :ping, t: 2 }))
    first = Timeout.timeout(3) { @received.pop }
    assert_equal 1, first[:env][:t]
    assert eof?(sock)
    assert @received.empty?, "the second frame was read with the one that closed the socket"
    sock.close
  ensure
    @close_on_frame = false
  end

  # One read a tick: a socket that wrote 200 KiB of tiny frames hands the loop at most
  # READ_CHUNK of them a tick - the rest wait in the kernel, and all arrive in the end.
  def test_one_read_a_tick
    @reactor.stop
    @thread.join(3)
    r = PEMK::Reactor.new(host: "127.0.0.1", port: 0, on_frame: method(:handle))
    r.start
    sock = TCPSocket.new("127.0.0.1", r.port)
    small = W.encode_split({ type: :ping, t: 1, pad: "p" * 150 })
    sock.write(small * 1000)
    sleep 0.3
    r.tick(0.5) until r.conn_count == 1
    got = @received.size
    r.tick(0.5) while @received.size == got
    first = @received.size
    assert_operator first, :<=, (PEMK::Reactor::READ_CHUNK / small.bytesize) + 1, "one read's worth"
    Timeout.timeout(5) { r.tick(0.5) until @received.size >= 1000 }
    assert_equal 1000, @received.size
    sock.close
    r.stop
    r.shutdown
  end

  # Before its session a socket may announce a small frame only (when asked); after, any.
  def test_a_big_frame_before_the_session_closes_the_socket
    @reactor.stop
    @thread.join(3)
    r = PEMK::Reactor.new(host: "127.0.0.1", port: 0, on_frame: method(:handle), preauth_frame_max: 1024)
    r.start
    t = Thread.new { r.run_loop }
    sock = TCPSocket.new("127.0.0.1", r.port)
    sock.write([2000].pack("N"))
    assert_nil Timeout.timeout(3) { sock.read(1) }, "closed"
    sock2 = TCPSocket.new("127.0.0.1", r.port)
    sock2.write(W.encode_split({ type: :ping, t: 1 }))
    Timeout.timeout(3) { @received.pop }
    @last_conn.data[:account_id] = 7   # a session
    sock2.write(W.encode_split({ type: :ping, t: 2, pad: "p" * 2000 }))
    assert_equal 2, Timeout.timeout(3) { @received.pop }[:env][:t]
    [sock, sock2].each(&:close)
    r.stop
    t.join(3)
  end

  # A socket closed while what its client sent is unread: the close must still deliver
  # what was sent to it (a ban's notice) - a close with unread input is a reset, and a
  # reset throws away the data still on its way to the client.
  def test_a_close_delivers_what_was_sent_before_it
    @reactor.stop
    @thread.join(3)
    r = nil
    closer = lambda do |conn, _payload|
      next if conn.data[:told]

      conn.data[:told] = true
      sleep 0.3   # the client's whole write is in by now, mostly unread
      r.send_frame(conn, W.encode_split({ type: :banned, note: "bye" }))
      r.finish(conn)
    end
    r = PEMK::Reactor.new(host: "127.0.0.1", port: 0, on_frame: closer)
    r.start
    t = Thread.new { r.run_loop }
    sock = TCPSocket.new("127.0.0.1", r.port)
    pad = W.encode_split({ type: :ping, pad: "p" * 4000 })
    sock.write(W.encode_split({ type: :ping, t: 1 }) + (pad * 50))   # far more than one read
    sleep 0.8
    got = begin
      read_frame(sock)
    rescue Errno::ECONNRESET => e
      flunk "the close was a reset: what was sent before it is lost (#{e.class})"
    end
    assert_equal :banned, got[:env][:type], "the notice arrives before the close"
    ended = begin
      Timeout.timeout(3) { sock.read(1) }
    rescue Errno::ECONNRESET
      :reset
    end
    assert_nil ended, "a clean end (a FIN): a reset is what a Windows client loses the notice to"
    sock.close
    r.stop
    t.join(3)
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
