#===============================================================================
# PokeMMO :: Session
#-------------------------------------------------------------------------------
# Owns the connection lifecycle for this game instance and exposes the singletons
# the rest of the SDK talks to (client / relay / self_id). Started lazily the
# first time we're in the overworld (see Pump), so $game_player / $game_map exist.
#
# ROLE :auto makes local testing trivial: the first instance to launch binds the
# port and hosts; the second finds the port busy and joins as a client — no
# config changes needed to test with two windows on one PC.
#===============================================================================
module PokeMMO
  @client  = nil
  @relay   = nil
  @self_id = nil
  @started = false

  def self.client;   @client;   end
  def self.relay;    @relay;    end
  def self.self_id;  @self_id;  end
  def self.started?; @started;  end

  def self.enabled?
    Config::ENABLED && Config::ROLE != :off
  end

  # Lightweight file logger (no reliable console at all stages under mkxp-z).
  def self.log(msg)
    File.open(File.expand_path("mmo.log"), "a") { |f| f.write("#{msg}\n") }
  rescue
    nil
  end

  def self.send_message(hash)
    c = @client
    return false unless c && c.connected?
    c.send_message(hash)
  end

  # Idempotent: opens the relay (if hosting) and the client connection. Sets
  # @started up front so a failure doesn't get retried every single frame.
  def self.ensure_started
    return if @started || !enabled?
    @started = true
    @self_id = "#{rand(1 << 30)}-#{rand(1 << 30)}"
    role = Config::ROLE
    begin
      if role == :host || role == :auto
        relay = RelayServer.new(Config::PORT, Config::BIND_HOST)
        if relay.start
          @relay = relay
          log("host: relay listening on #{Config::BIND_HOST}:#{Config::PORT}")
        else
          @relay = nil
          if role == :auto
            role = :client   # port busy => another instance hosts; join it
            log("auto: port #{Config::PORT} busy, joining as client")
          else
            log("host: relay FAILED to bind port #{Config::PORT}")
          end
        end
      end
      target = (role == :client) ? Config::HOST : "127.0.0.1"
      @client = NetClient.new(target, Config::PORT)
      if @client.connect
        log("client: connected to #{target}:#{Config::PORT} (id #{@self_id})")
        Presence.emit(:pos)
      else
        log("client: FAILED to connect to #{target}:#{Config::PORT}")
      end
    rescue => e
      log("start error: #{e.class}: #{e.message}")
    end
  end

  def self.shutdown
    (@client.close if @client) rescue nil
    (@relay.stop  if @relay)  rescue nil
    @client = nil
    @relay = nil
    @started = false
  end
end
