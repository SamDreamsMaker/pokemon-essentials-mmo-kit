#===============================================================================
# PokeMMO :: RelayServer
#-------------------------------------------------------------------------------
# The Phase 1 "walking skeleton" server: a dumb, authority-less TCP relay. It
# accepts client connections and rebroadcasts every inbound frame to all OTHER
# connected clients — pure presence/position fan-out, no game logic.
#
# ARCHITECTURE (shaped by measured mkxp-z behaviour, see architecture doc §4):
#   * ONE background thread only — a blocking `accept` loop — which just hands
#     newly accepted sockets to a thread-safe Queue. (Blocking accept on a
#     main-spawned thread is the one threading pattern that tested reliable;
#     select-on-listening-socket and non-main-spawned threads did NOT.)
#   * Everything else runs on the MAIN thread via #pump (called once per frame):
#     it registers freshly accepted clients and relays their frames using
#     read_nonblock. No thread-per-client — which also fixes the scaling cost
#     the audit flagged (§10-G7).
#
# The relay NEVER decodes (Marshal.load) client bytes: it forwards the raw
# length-prefixed frame as-is, keeping the untrusted-deserialisation trust
# boundary on the clients (MessageCodec, architecture doc §5/§10).
#
# Same MRI runtime as the client: the "host on Windows" model runs this
# in-process; a dedicated Linux server runs the same code headless.
#===============================================================================
module PokeMMO
  class RelayServer
    attr_reader :port, :frames_in, :frames_out   # simple metrics / observability

    def initialize(port = Config::PORT, host = "0.0.0.0")
      @port     = port
      @host     = host
      @server   = nil
      @acceptor = nil
      @pending  = Queue.new    # accepted sockets, acceptor-thread -> main #pump
      @clients  = {}           # id => socket   (main thread / #pump only)
      @buffers  = {}           # id => partial-read buffer
      @running  = false
      @next_id  = 0
      @frames_in  = 0
      @frames_out = 0
    end

    # Binds and starts accepting. Returns true on success (never raises).
    # Call from the main thread (the acceptor must be main-spawned).
    def start
      require "socket"
      @server  = TCPServer.new(@host, @port)
      @port    = @server.addr[1]      # resolve the real port (handles port 0)
      @running = true
      @acceptor = Thread.new do
        while @running
          sock = (@server.accept rescue nil)
          break unless sock
          @pending << sock
        end
      end
      true
    rescue => e
      @running = false
      false
    end

    def running?
      @running
    end

    def client_count
      @clients.size
    end

    # Drives the server. Call once per frame from the MAIN thread:
    #   1. registers any newly accepted clients,
    #   2. reads whatever each client has sent and relays it to the others.
    def pump
      register_pending
      @clients.to_a.each do |id, sock|
        dropped = false
        loop do
          # exception: false -> returns :wait_readable (no data) or nil (EOF)
          # instead of raising, which kept spamming the console every frame.
          data = (sock.read_nonblock(4096, exception: false) rescue nil)
          break if data == :wait_readable
          if data.nil?              # EOF or socket error
            drop(id); dropped = true; break
          end
          @buffers[id] << data
        end
        relay_frames(id) unless dropped
      end
    end

    # Stops the server and closes all links. Idempotent.
    def stop
      @running = false
      (@server.close if @server) rescue nil
      (@acceptor.join(1) if @acceptor) rescue nil
      @clients.each_value { |s| s.close rescue nil }
      @clients.clear
      @buffers.clear
    end

    # Send a message to ONE connection (authoritative server -> specific client).
    # Public: called by ServerLogic to answer a login/save. Runs on the pump
    # (main) thread, like every other server write, so no locking is needed.
    def send_to(conn_id, msg)
      sock = @clients[conn_id]
      return false unless sock
      sock.write(MessageCodec.encode(msg))
      true
    rescue
      drop(conn_id)
      false
    end

    private

    def register_pending
      # Guard with empty? so pop(true) never raises ThreadError on an empty queue
      # (which was being logged every frame).
      until @pending.empty?
        sock = (@pending.pop(true) rescue nil)
        break unless sock
        id = (@next_id += 1)
        @clients[id] = sock
        @buffers[id] = "".b
      end
    end

    def relay_frames(id)
      buf = @buffers[id]
      loop do
        break if buf.bytesize < Config::LENGTH_BYTES
        len = buf[0, Config::LENGTH_BYTES].unpack1("N")
        return drop(id) if len > Config::MAX_MESSAGE_BYTES
        total = Config::LENGTH_BYTES + len
        break if buf.bytesize < total
        frame = buf.slice!(0, total)
        @frames_in += 1
        route(id, frame)
      end
    end

    # Decode just enough to route: account messages (login/save) are handled by
    # the authoritative ServerLogic and answered to the sender only; everything
    # else (presence) is forwarded raw to the other clients, as in Phase 1.
    def route(sender_id, frame)
      payload = frame[Config::LENGTH_BYTES, frame.bytesize - Config::LENGTH_BYTES]
      msg = MessageCodec.decode(payload)
      if msg.is_a?(Hash) && Config::ACCOUNT_TYPES.include?(msg[:type])
        PokeMMO::ServerLogic.handle(self, sender_id, msg)
      else
        broadcast(sender_id, frame)
      end
    end

    # Fan a pre-framed message out to every client except the sender.
    def broadcast(sender_id, frame)
      n = 0
      @clients.each do |cid, sock|
        next if cid == sender_id
        (sock.write(frame); n += 1) rescue nil
      end
      @frames_out += n
    end

    def drop(id)
      s = @clients.delete(id)
      @buffers.delete(id)
      (s.close if s) rescue nil
      (PokeMMO::ServerLogic.forget(id) rescue nil)
    end
  end
end
