#===============================================================================
# PEMK :: NetClient
#-------------------------------------------------------------------------------
# Owns one TCP connection, fully NON-BLOCKING and single-threaded: all I/O runs
# on the main (game) thread. #poll is called once per frame; it drains whatever
# bytes are available (read_nonblock), reassembles length-prefixed frames, and
# returns the decoded messages.
#
# Why no background reader thread? Phase 0 + Phase 1 testing showed mkxp-z's
# thread scheduler is unreliable for this pattern (threads spawned by non-main
# threads are starved; select on a listening socket misses pending connections).
# read_nonblock on the main thread was validated in Phase 0 and is deterministic.
# During blocking game loops (battles/menus) where :on_frame_update doesn't fire,
# the SDK pumps this from an alias of pbUpdateSceneMap (see architecture doc §4).
#
# Facade over the raw socket; MessageCodec is the only serialisation boundary.
# Non-raising by contract: a dropped link surfaces as a DISCONNECTED message from
# #poll and #connected? going false — never an exception into the game loop.
#===============================================================================
module PEMK
  class NetClient
    DISCONNECTED = :__disconnected__

    def initialize(host = Config::HOST, port = Config::PORT)
      @host      = host
      @port      = port
      @socket    = nil
      @buffer    = "".b        # partial-frame accumulator
      @connected = false
      @dropped   = false       # a WRITE noticed the drop; poll reports it once
    end

    def connected?
      @connected
    end

    # Opens the connection (a brief, BOUNDED blocking connect on the main thread).
    # Returns true on success, false on failure (never raises).
    def connect
      require "socket"
      @socket = open_socket
      return false unless @socket

      @socket.sync = true
      @buffer = "".b
      @connected = true
      @dropped = false
      true
    rescue => e
      @connected = false
      false
    end

    # Sends a message Hash, optionally with an opaque body (raw bytes). ALWAYS a
    # split frame: a primitive-only envelope plus the untouched body, so the host
    # never Marshal.loads anything we send. An unencodable message (a stray
    # non-primitive envelope field) is dropped and logged — it must not take down
    # the link; only a socket error disconnects. Main-thread write; never raises.
    def send_message(msg, body = nil)
      return false unless @connected
      begin
        frame = MessageCodec.encode_split(msg, body)
      rescue => e
        PEMK.log("net: dropping unencodable #{msg[:type].inspect}: #{e.class}: #{e.message}")
        return false
      end
      @socket.write(frame)
      true
    rescue => e
      # A silent network death (no FIN/RST) is often first noticed by a WRITE.
      # Flag it so the next poll emits DISCONNECTED — otherwise the reconnect FSM
      # would never be armed and the rest of the session would silently unsync.
      @connected = false
      @dropped   = true
      false
    end

    # Drains all bytes available right now and returns the decoded messages
    # (possibly empty). Call once per frame from the main thread. On a dropped
    # link, returns a single { :type => DISCONNECTED } message and flips
    # #connected? to false.
    def poll
      unless @connected && @socket
        if @dropped                       # write-detected drop: report it exactly once
          @dropped = false
          return [{ :type => DISCONNECTED }]
        end
        return []
      end
      msgs = []
      loop do
        # exception: false -> :wait_readable (no data) or nil (EOF), no raise
        # (raising WaitReadable every frame was spamming the console).
        data = (@socket.read_nonblock(4096, exception: false) rescue nil)
        break if data == :wait_readable
        if data.nil?               # EOF or socket error
          @connected = false
          msgs << { :type => DISCONNECTED }
          break
        end
        @buffer << data
      end
      extract_frames(msgs)
      msgs
    end

    def close
      @connected = false
      s = @socket
      @socket = nil
      (s.close if s) rescue nil
    end

    private

    # Plain blocking connect. mkxp-z ships the socket C extension but NOT the
    # stdlib socket.rb layer, so neither Socket.tcp NOR Socket#connect_nonblock
    # exist there (both were tried and raise NoMethodError). TCPSocket.new is the
    # only connect primitive available. A DEAD LOCALHOST PORT refuses instantly
    # (no timeout), which is the case that matters for dev + the reconnect FSM
    # against a killed local server. A genuinely-unreachable ROUTED host would
    # block for the OS timeout — an accepted residual for remote play until a
    # thread-free bound is found. -> connected Socket | nil.
    def open_socket
      TCPSocket.new(@host, @port)
    rescue StandardError
      nil
    end

    # Pulls every whole [uint32 len][payload] frame out of @buffer, decodes it,
    # and appends it to +msgs+.
    def extract_frames(msgs)
      loop do
        break if @buffer.bytesize < Config::LENGTH_BYTES
        len = @buffer[0, Config::LENGTH_BYTES].unpack1("N")
        if len > Config::MAX_MESSAGE_BYTES
          @connected = false
          msgs << { :type => DISCONNECTED }
          return
        end
        total = Config::LENGTH_BYTES + len
        break if @buffer.bytesize < total
        payload = @buffer.slice!(0, total)[Config::LENGTH_BYTES, len]
        dec = MessageCodec.decode_envelope(payload)
        next if dec.nil?
        m = dec[:env]
        m[:_body] = dec[:body] if dec[:body]   # opaque bytes; the consumer loads them
        msgs << m
      end
    end
  end
end
