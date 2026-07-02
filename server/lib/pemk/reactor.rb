# frozen_string_literal: true

require "socket"
require "thread"

module PEMK
  # Single-threaded, non-blocking TCP reactor on stdlib IO.select — no async gem,
  # no nio4r. Owns the listen socket + every client socket, slices length-prefixed
  # frames into per-connection buffers, and drains a bounded per-connection
  # outbound buffer (backpressure: a slow client is dropped, never blocks the loop).
  #
  # Off-thread work (DB, bcrypt) runs on a worker pool; a worker hands a reply back
  # by calling #post(&block), which wakes the reactor through a self-pipe and runs
  # the block ON THE REACTOR THREAD — so all connection state and socket writes stay
  # single-threaded and lock-free.
  class Reactor
    OUTBUF_CAP = 4 << 20
    READ_CHUNK = 64 * 1024
    LEN_BYTES  = 4
    MAX_FRAME  = PEMK::Wire::MAX_MESSAGE_BYTES

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
      @on_frame = on_frame
      @on_close = on_close
      @log      = logger || ->(_m) {}
      @conns    = {}
      @running  = false
      @posts    = Queue.new
      @wmutex   = Mutex.new
      @wake_r, @wake_w = IO.pipe
    end

    def start
      @server  = TCPServer.new(@host, @port)
      @port    = @server.addr[1]
      @running = true
      @log.call("reactor: listening on #{@host}:#{@port}")
    end

    def stop
      @running = false
      wake!   # break the IO.select so the loop notices @running == false
    end

    def running?
      @running
    end

    def conn_count
      @conns.size
    end

    def run
      start unless @server
      run_loop
    end

    def run_loop
      while @running
        begin
          tick
        rescue StandardError => e
          @log.call("reactor: tick error #{e.class}: #{e.message}")
        end
      end
    ensure
      shutdown
    end

    def tick(timeout = 0.5)
      reads  = [@server, @wake_r, *@conns.keys]
      writes = @conns.values.select(&:want_write?).map(&:io)
      readable, writable, = IO.select(reads, (writes.empty? ? nil : writes), nil, timeout)
      readable&.each do |io|
        if    io.equal?(@server) then accept_conns
        elsif io.equal?(@wake_r) then drain_wake
        else  read_conn(@conns[io])
        end
      end
      writable&.each { |io| write_conn(@conns[io]) }
    end

    # Thread-safe: schedule a block to run on the reactor thread and wake it.
    def post(&block)
      @posts << block
      wake!
    end

    # Reactor-thread only. Queue a frame to a live connection, try to flush now.
    def send_frame(conn, frame)
      return if conn.nil? || conn.closing || !@conns.key?(conn.io)

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
      (@wake_r.close rescue nil)
      (@wake_w.close rescue nil)
    end

    private

    def wake!
      @wmutex.synchronize { @wake_w.write("x") }
    rescue IOError, SystemCallError
      nil
    end

    def drain_wake
      loop do
        d = @wake_r.read_nonblock(4096, exception: false)
        break if d == :wait_readable || d.nil?
      end
      loop do
        block = (@posts.pop(true) rescue nil)
        break unless block

        block.call
      end
    end

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
        return close_conn(conn) if data.nil?
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
        if conn.closing
          close_conn(conn) if conn.outbuf.empty?   # else write_conn closes after flush
          return
        end
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
