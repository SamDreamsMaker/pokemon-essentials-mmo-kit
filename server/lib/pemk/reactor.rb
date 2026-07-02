# frozen_string_literal: true

require "socket"

module PEMK
  # Single-threaded, non-blocking TCP reactor built on stdlib IO.select — no async
  # gem, no nio4r. It owns the listen socket + every client socket, slices
  # length-prefixed frames out of per-connection inbound buffers, and drains a
  # bounded per-connection outbound buffer (backpressure; a slow client is dropped
  # rather than blocking the loop). It knows NOTHING about message semantics: it
  # hands complete frame payloads to on_frame and lets the caller decode/route.
  class Reactor
    OUTBUF_CAP = 4 << 20            # 4 MiB per-conn outbound cap -> drop slow client
    READ_CHUNK = 64 * 1024
    LEN_BYTES  = 4
    MAX_FRAME  = PEMK::Wire::MAX_MESSAGE_BYTES

    # Per-connection state. `data` is a free-form Hash for the app layer (auth,
    # account_id, current map_id for zone presence, ...).
    class Conn
      attr_reader :io, :addr
      attr_accessor :inbuf, :outbuf, :closing, :data

      def initialize(io, addr)
        @io      = io
        @addr    = addr
        @inbuf   = +"".b
        @outbuf  = +"".b
        @closing = false
        @data    = {}
      end

      def want_write?
        !@outbuf.empty?
      end
    end

    attr_reader :port

    def initialize(host:, port:, on_frame:, on_close: nil, logger: nil)
      @host     = host
      @port     = port
      @on_frame = on_frame          # ->(conn, payload)
      @on_close = on_close          # ->(conn)
      @log      = logger || ->(_m) {}
      @conns    = {}                # io => Conn
      @running  = false
    end

    def start
      @server  = TCPServer.new(@host, @port)
      @port    = @server.addr[1]
      @running = true
      @log.call("reactor: listening on #{@host}:#{@port}")
    end

    def stop
      @running = false
    end

    def running?
      @running
    end

    def conn_count
      @conns.size
    end

    def run
      start unless @server
      tick while @running
    ensure
      shutdown
    end

    # One select/read/write cycle. Exposed for deterministic tests.
    def tick(timeout = 0.5)
      reads  = [@server, *@conns.keys]
      writes = @conns.values.select(&:want_write?).map(&:io)
      readable, writable, = IO.select(reads, (writes.empty? ? nil : writes), nil, timeout)
      readable&.each { |io| io.equal?(@server) ? accept_conns : read_conn(@conns[io]) }
      writable&.each { |io| write_conn(@conns[io]) }
    end

    # Queue a frame to a connection and try to flush immediately. Safe to call
    # from the reactor thread (the app handler runs there today; a worker pool
    # will wake the reactor via a self-pipe in a later milestone).
    def send_frame(conn, frame)
      return if conn.nil? || conn.closing

      conn.outbuf << frame
      if conn.outbuf.bytesize > OUTBUF_CAP
        @log.call("reactor: outbuf overflow #{conn.addr} -> drop")
        close_conn(conn)
      else
        write_conn(conn)
      end
    end

    def shutdown
      (@server.close rescue nil) if @server
      @conns.values.each { |c| close_conn(c) }
      @conns.clear
    end

    private

    def accept_conns
      loop do
        io = @server.accept_nonblock(exception: false)
        break if io == :wait_readable || io.nil?

        addr = (io.peeraddr[3] rescue "?")
        @conns[io] = Conn.new(io, addr)
        @log.call("reactor: + #{addr} (#{@conns.size})")
      end
    end

    def read_conn(conn)
      return unless conn

      loop do
        data = conn.io.read_nonblock(READ_CHUNK, exception: false)
        return close_conn(conn) if data.nil?           # EOF
        break if data == :wait_readable

        conn.inbuf << data
        return close_conn(conn) if conn.inbuf.bytesize > MAX_FRAME + LEN_BYTES
      end
      slice_frames(conn)
    rescue IOError, SystemCallError
      close_conn(conn)
    end

    def slice_frames(conn)
      buf = conn.inbuf
      loop do
        break if buf.bytesize < LEN_BYTES

        len = buf.byteslice(0, LEN_BYTES).unpack1("N")
        return close_conn(conn) if len > MAX_FRAME

        total = LEN_BYTES + len
        break if buf.bytesize < total

        payload = buf.byteslice(LEN_BYTES, len)
        conn.inbuf = buf = (buf.byteslice(total, buf.bytesize - total) || +"".b)
        @on_frame.call(conn, payload)
        return if conn.closing
      end
    end

    def write_conn(conn)
      return unless conn && !conn.outbuf.empty?

      loop do
        n = conn.io.write_nonblock(conn.outbuf, exception: false)
        break if n == :wait_writable

        conn.outbuf = (conn.outbuf.byteslice(n, conn.outbuf.bytesize - n) || +"".b)
        break if conn.outbuf.empty?
      end
      close_conn(conn) if conn.closing && conn.outbuf.empty?
    rescue IOError, SystemCallError
      close_conn(conn)
    end

    def close_conn(conn)
      return unless conn && @conns.key?(conn.io)

      @conns.delete(conn.io)
      (conn.io.close rescue nil)
      @on_close&.call(conn)
      @log.call("reactor: - #{conn.addr} (#{@conns.size})")
    end
  end
end
