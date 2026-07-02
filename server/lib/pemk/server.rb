# frozen_string_literal: true

require "time"
require "set"

module PEMK
  # Milestone 1 server: reactor + worker pool + a connection AUTH-GATE. A socket is
  # unauthenticated (only :ping/:register/:login/:auth accepted, everything else
  # dropped) until it presents valid credentials or a session token — this retires
  # the old client-claimed account_id and closes the impersonation hole. Blocking
  # work (Postgres, bcrypt) runs on the pool; replies come back via reactor.post so
  # connection state and socket writes stay single-threaded.
  #
  # Per-player mailbox routing, zone presence and the save store are the next
  # increments; authenticated gameplay frames are logged here for now.
  class Server
    AUTH_TYPES     = %i[ping register login auth].freeze
    WORKERS        = 8
    LOGIN_MAX      = 10          # login/register attempts ...
    LOGIN_WINDOW   = 60          # ... per this many seconds, per IP

    def self.log(msg)
      $stdout.puts("#{Time.now.utc.iso8601} #{msg}")
      $stdout.flush
    end

    def initialize(config: Config.new, logger: nil)
      @config   = config
      @log      = logger || self.class.method(:log)
      @db       = DB.connect(@config.database_url, max_connections: WORKERS + 2)
      @accounts   = Accounts.new(@db)
      @sessions   = Sessions.new(@db)
      @characters = Characters.new(@db)
      @pool     = WorkerPool.new(size: WORKERS, logger: @log)
      @limiter  = RateLimiter.new(max: LOGIN_MAX, per: LOGIN_WINDOW)
      @zones    = Hash.new { |h, k| h[k] = Set.new }   # map_id => Set(conn); reactor-thread only
      @reactor  = Reactor.new(
        host: @config.bind, port: @config.port,
        on_frame: method(:on_frame), on_close: method(:on_close), logger: @log
      )
    end

    def port
      @reactor.port
    end

    def start
      @db.test_connection
      @log.call("server: db ok (#{@db.opts[:database]}), workers=#{WORKERS}")
      @log.call("server: economy caps #{@config.economy_caps}, badges<#{@config.badges_max}")
      @pool.start
      @reactor.start
      @thread = Thread.new { @reactor.run_loop }
      @thread.abort_on_exception = true
    end

    def stop
      @reactor.stop
      @thread&.join(5)
      @pool.shutdown
      @log.call("server: stopped")
    end

    def run
      install_signal_handlers
      start
      @thread.join           # block until SIGTERM stops the reactor
      @pool.shutdown
      @log.call("server: stopped")
    end

    private

    def on_frame(conn, payload)
      dec = Wire.decode_envelope(payload, false) # host path rejects legacy whole-Marshal
      unless dec
        @log.call("server: bad/legacy frame from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      env    = dec[:env]
      type   = env[:type]
      authed = conn.data[:account_id]

      unless authed || AUTH_TYPES.include?(type)
        @log.call("server: pre-auth #{type.inspect} from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      case type
      when :ping     then reply(conn, type: :pong, t: env[:t])
      when :register then handle_register(conn, env)
      when :login    then handle_login(conn, env)
      when :auth     then handle_auth(conn, env)
      when :save     then handle_save(env, dec[:body], authed)
      when :pos, :dir, :step, :spawn then handle_presence(conn, env, authed)
      else
        # Other authenticated gameplay frames (economy, battle) — per-player mailbox
        # routing + handlers land in later milestones.
        @log.call("server: authed #{type.inspect} from account #{authed}")
      end
    end

    def handle_register(conn, env)
      return reply(conn, type: :register_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      user  = env[:username].to_s
      pw    = env[:password].to_s
      email = env[:email]
      @pool.submit do
        result =
          begin
            id = @accounts.create(username: user, password: pw, email: email)
            id ? { type: :register_ok, account_id: id } : { type: :register_err, reason: "taken" }
          rescue ArgumentError => e
            { type: :register_err, reason: e.message }
          end
        @reactor.post { reply(conn, **result) }
      end
    end

    def handle_login(conn, env)
      return reply(conn, type: :login_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      user = env[:username].to_s
      pw   = env[:password].to_s
      addr = conn.addr
      @pool.submit do
        acct, err = @accounts.authenticate(user, pw)
        if acct
          token = @sessions.issue(acct[:id], remote_addr: addr)
          blob  = @characters.load_blob(acct[:id])   # opaque; never loaded here
          @reactor.post do
            bind(conn, acct[:id])
            reply_body(conn, { type: :login_ok, account_id: acct[:id], token: token }, blob)
          end
        else
          @reactor.post { reply(conn, type: :login_err, reason: err.to_s) }
        end
      end
    end

    def handle_auth(conn, env)
      token = env[:token].to_s
      @pool.submit do
        account_id = @sessions.resolve(token)
        if account_id
          blob = @characters.load_blob(account_id)
          @reactor.post do
            bind(conn, account_id)
            reply_body(conn, { type: :auth_ok, account_id: account_id }, blob)
          end
        else
          @reactor.post { reply(conn, type: :auth_err, reason: "invalid_token") }
        end
      end
    end

    # Persist the opaque save body (never Marshal.load'd server-side). Fire-and-
    # forget on the pool; the client's local save is the immediate copy.
    def handle_save(env, body, account_id)
      unless body.is_a?(String) && !body.empty?
        @log.call("server: empty :save from account #{account_id} -> ignore")
        return
      end

      tid = env[:trainer_id]
      sv  = env[:save_version]
      wv  = env[:wire_version]
      @pool.submit do
        @characters.store(account_id, blob: body, trainer_id: tid, save_version: sv, wire_version: wv)
        @log.call("server: saved account #{account_id} (#{body.bytesize}B)")
      end
    end

    # Zone-scoped presence: track each player's current map and fan a position
    # update out ONLY to same-map connections (the 500-CCU lever). Runs inline on
    # the reactor thread — cheap, in-memory, no DB. Identity is the server-trusted
    # account_id, not the client-provided :id (anti-spoof).
    def handle_presence(conn, env, account_id)
      map = env[:map]
      return unless map.is_a?(Integer)

      old = conn.data[:map_id]
      if old && old != map
        @zones[old].delete(conn)
        broadcast_zone(old, conn, Wire.encode_split({ type: :leave, id: account_id }))
      end
      @zones[map].add(conn)
      conn.data[:map_id] = map

      broadcast_zone(map, conn, Wire.encode_split(env.merge(id: account_id)))
    end

    def broadcast_zone(map, sender, frame)
      @zones[map].each { |c| @reactor.send_frame(c, frame) unless c.equal?(sender) }
    end

    def bind(conn, account_id)
      conn.data[:account_id] = account_id
      @log.call("server: authed #{conn.addr} as account #{account_id}")
    end

    def reply(conn, **env)
      @reactor.send_frame(conn, Wire.encode_split(env))
    end

    def reply_body(conn, env, body)
      @reactor.send_frame(conn, Wire.encode_split(env, body))
    end

    def on_close(conn)
      map = conn.data[:map_id]
      return unless map

      @zones[map].delete(conn)
      aid = conn.data[:account_id]
      broadcast_zone(map, conn, Wire.encode_split({ type: :leave, id: aid })) if aid
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { @reactor.stop } }
    end
  end
end
