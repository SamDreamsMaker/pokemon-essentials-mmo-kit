#===============================================================================
# PEMK :: Session
#-------------------------------------------------------------------------------
# Owns the connection lifecycle for this game instance and exposes the singletons
# the rest of the SDK talks to (client / relay / self_id). Started lazily the
# first time we're in the overworld (see Pump), so $game_player / $game_map exist.
#
# ROLE :auto makes local testing trivial: the first instance to launch binds the
# port and hosts; the second finds the port busy and joins as a client — no
# config changes needed to test with two windows on one PC.
#===============================================================================
module PEMK
  @client  = nil
  @relay   = nil
  @self_id = nil
  @started = false

  def self.client;   @client;   end
  def self.relay;    @relay;    end
  def self.self_id;  @self_id;  end
  def self.started?; @started;  end

  # Phase 2: once the server issues a stable account/trainer id at login, it
  # becomes our presence id too (so a player's presence and account align).
  def self.set_self_id(v)
    @self_id = v
  end

  # Effective connection settings: Config defaults, overridden by an optional
  # plain-text mmo_config.txt in the game folder (so friends can set up LAN play
  # without touching Ruby). Resolved once, on first use.
  def self.settings
    @settings ||= resolve_settings
  end

  def self.resolve_settings
    s = { :role => Config::ROLE, :host => Config::HOST,
          :port => Config::PORT, :bind => Config::BIND_HOST }
    path = File.expand_path(Config::CONFIG_FILE)
    if File.exist?(path)
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        k, v = line.split("=", 2)
        next unless k && v
        k = k.strip.downcase
        v = v.strip
        case k
        when "role" then s[:role] = v.downcase.to_sym
        when "host" then s[:host] = v
        when "port" then s[:port] = v.to_i if v.to_i > 0
        when "bind" then s[:bind] = v
        end
      end
      log("config: #{Config::CONFIG_FILE} -> role=#{s[:role]} host=#{s[:host]} port=#{s[:port]} bind=#{s[:bind]}")
    end
    s
  rescue => e
    log("config: error reading #{Config::CONFIG_FILE}: #{e.class}: #{e.message}")
    { :role => Config::ROLE, :host => Config::HOST, :port => Config::PORT, :bind => Config::BIND_HOST }
  end

  def self.enabled?
    Config::ENABLED && settings[:role] != :off
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
    st   = settings
    role = st[:role]
    port = st[:port]
    begin
      if role == :host || role == :auto
        relay = RelayServer.new(port, st[:bind])
        if relay.start
          @relay = relay
          log("host: relay listening on #{st[:bind]}:#{port}")
        else
          @relay = nil
          if role == :auto
            role = :client   # port busy => another instance hosts; join it
            log("auto: port #{port} busy, joining as client")
          else
            log("host: relay FAILED to bind port #{port}")
          end
        end
      end
      target = (role == :client) ? st[:host] : "127.0.0.1"
      @client = NetClient.new(target, port)
      if @client.connect
        log("client: connected to #{target}:#{port} (id #{@self_id})")
        Presence.emit(:pos)
      else
        log("client: FAILED to connect to #{target}:#{port}")
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
