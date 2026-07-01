#===============================================================================
# PokeMMO :: NetClient
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
module PokeMMO
  class NetClient
    DISCONNECTED = :__disconnected__

    def initialize(host = Config::HOST, port = Config::PORT)
      @host      = host
      @port      = port
      @socket    = nil
      @buffer    = "".b        # partial-frame accumulator
      @connected = false
    end

    def connected?
      @connected
    end

    # Opens the connection (a brief blocking connect on the main thread).
    # Returns true on success, false on failure (never raises).
    def connect
      require "socket"
      @socket = TCPSocket.new(@host, @port)
      @socket.sync = true
      @buffer = "".b
      @connected = true
      true
    rescue => e
      @connected = false
      false
    end

    # Sends a message Hash. Main-thread write; never raises.
    def send_message(msg)
      return false unless @connected
      @socket.write(MessageCodec.encode(msg))
      true
    rescue => e
      @connected = false
      false
    end

    # Drains all bytes available right now and returns the decoded messages
    # (possibly empty). Call once per frame from the main thread. On a dropped
    # link, returns a single { :type => DISCONNECTED } message and flips
    # #connected? to false.
    def poll
      return [] unless @connected && @socket
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
        m = MessageCodec.decode(payload)
        msgs << m unless m.nil?
      end
    end
  end
end
