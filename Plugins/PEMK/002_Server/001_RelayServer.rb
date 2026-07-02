#===============================================================================
# PEMK :: RelayServer
#-------------------------------------------------------------------------------
# An authority-light TCP relay. It accepts client connections and moves frames
# between them: account messages (login/save/economy) are handled by the
# authoritative ServerLogic, ADDRESSED frames (those carrying a :to account id —
# challenges, team exchange, the whole battle stream) go to ONLY that recipient,
# and unaddressed presence frames fan out to everyone else. No game simulation.
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
# The relay decodes only each frame's small envelope (MessageCodec) to choose a
# route; it then forwards the ORIGINAL raw length-prefixed frame unchanged, so it
# never re-serialises game payloads. (Marshal-decoding untrusted client bytes here
# is the same trust boundary the clients already accept — replacing Marshal with a
# safe codec is a separate hardening step, architecture doc §5/§10.)
#
# Same MRI runtime as the client: the "host on Windows" model runs this
# in-process; a dedicated Linux server runs the same code headless.
#===============================================================================
module PEMK
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

    # Decode only the frame's envelope to pick a route, then forward the ORIGINAL
    # raw frame unchanged:
    #   * account messages (login/save/economy) -> authoritative ServerLogic;
    #   * addressed frames (a :to account id: challenges, team exchange, the whole
    #     battle stream) -> ONLY that recipient (unicast), so private payloads
    #     never reach any other client;
    #   * everything else (presence, no :to) -> every other client (broadcast).
    def route(sender_id, frame)
      payload = frame[Config::LENGTH_BYTES, frame.bytesize - Config::LENGTH_BYTES]
      # Decode ONLY the envelope. For a split frame the opaque body is never
      # Marshal.loaded here — the host routes on primitives alone. (Legacy frames
      # still whole-Marshal via decode_envelope until senders migrate.)
      dec = MessageCodec.decode_envelope(payload)
      return unless dec   # undecodable / oversized / hostile envelope -> drop, never broadcast
      msg = dec[:env]
      if Config::ACCOUNT_TYPES.include?(msg[:type])
        PEMK::ServerLogic.handle(self, sender_id, msg, dec[:body])
      elsif !msg[:to].nil?
        unicast(sender_id, msg, frame)
      else
        broadcast(sender_id, frame)
      end
    end

    # Deliver an ADDRESSED frame to only its :to account's connection, so private
    # payloads (teams, per-round choices, the RNG stream) are invisible to every
    # other connected client. If the recipient is unknown/offline, DROP the frame
    # rather than fall back to broadcast — broadcasting it would re-open the exact
    # leak this routing exists to close.
    def unicast(sender_id, msg, frame)
      conn = (PEMK::ServerLogic.conn_for(msg[:to]) rescue nil)
      if conn.nil? || conn == sender_id
        PEMK.log("relay: no route for #{msg[:type]} -> account #{msg[:to].inspect}")
        return
      end
      sock = @clients[conn]
      return unless sock
      sock.write(frame)
      @frames_out += 1
    rescue
      drop(conn)
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
      (PEMK::ServerLogic.forget(id) rescue nil)
    end
  end
end
