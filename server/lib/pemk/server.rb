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
    # Authenticated point-to-point frames the server relays to the :to account
    # (challenge handshake + the whole battle stream), the role the old in-process
    # relay played — now with server-trusted :from and no cross-client leakage.
    ADDRESSED      = %i[challenge challenge_accept challenge_decline battle_team
                        battle_start battle_choice battle_round battle_switch battle_end].freeze
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
      @ledger     = Ledger.new(@db, @config.economy_caps)
      @inventory  = Inventory.new(@db, @config.inventory_caps, logger: @log)
      @pool     = WorkerPool.new(size: WORKERS, logger: @log)
      @limiter  = RateLimiter.new(max: LOGIN_MAX, per: LOGIN_WINDOW)
      @zones    = Hash.new { |h, k| h[k] = Set.new }   # map_id => Set(conn); reactor-thread only
      @online   = {}                                    # account_id => conn; reactor-thread only
      @reactor  = Reactor.new(
        host: @config.bind, port: @config.port,
        on_frame: method(:on_frame), on_close: method(:on_close), logger: @log
      )
      @mailbox  = PlayerMailbox.new(pool: @pool, post: @reactor.method(:post), logger: @log)
    end

    def port
      @reactor.port
    end

    def start
      @db.test_connection
      @log.call("server: db ok (#{@db.opts[:database]}), workers=#{WORKERS}")
      @log.call("server: economy caps #{@config.economy_caps}, badges<#{@config.badges_max}")
      @log.call("server: inventory caps #{@config.inventory_caps} (detection-only, flag-not-reject)")
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
      when :econ     then handle_econ(conn, env, authed)
      when :inv      then handle_inv(conn, env, authed)
      when :pos, :dir, :step, :spawn then handle_presence(conn, env, authed)
      when *ADDRESSED then handle_addressed(conn, env, dec[:body], authed)
      else
        # Other authenticated gameplay frames (economy, battle) — per-player mailbox
        # routing + handlers land in later milestones.
        @log.call("server: authed #{type.inspect} from account #{authed}")
      end
    end

    def handle_register(conn, env)
      return reply(conn, type: :register_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      email = env[:email].to_s
      pw    = env[:password].to_s
      uname = env[:username]   # optional display handle
      @pool.submit do
        result =
          begin
            id = @accounts.create(email: email, password: pw, username: uname)
            id ? { type: :register_ok, account_id: id } : { type: :register_err, reason: "taken" }
          rescue ArgumentError => e
            { type: :register_err, reason: e.message }
          end
        @reactor.post { reply(conn, **result) }
      end
    end

    def handle_login(conn, env)
      return reply(conn, type: :login_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      email = env[:email].to_s
      pw    = env[:password].to_s
      addr  = conn.addr
      @pool.submit do
        acct, err = @accounts.authenticate(email, pw)
        if acct
          token = @sessions.issue(acct[:id], remote_addr: addr)
          blob  = @characters.load_blob(acct[:id])   # opaque; never loaded here
          rec   = reconcile_block(acct[:id])
          @reactor.post do
            bind(conn, acct[:id])
            reply_body(conn, { type: :login_ok, account_id: acct[:id], token: token }.merge(rec), blob)
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
          rec  = reconcile_block(account_id)
          @reactor.post do
            bind(conn, account_id)
            reply_body(conn, { type: :auth_ok, account_id: account_id }.merge(rec), blob)
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

    # Server-authoritative economy. Serialized per account on the mailbox: apply the
    # absolute value through the ledger (cap-checked, gap-safe idempotent), then
    # ACK the canonical balance or REJECT (the client rolls back to it).
    def handle_econ(conn, env, account_id)
      field = env[:field]
      value = env[:value]
      seq   = env[:seq]
      @mailbox.submit(account_id) do
        status = @ledger.apply_econ(account_id, field, value, seq)
        @reactor.post do
          case status.first
          when :ack, :dup then reply(conn, type: :econ_ack, field: field, value: status[1], seq: seq)
          when :rej       then reply(conn, type: :econ_rej, field: field, value: status[1], seq: seq, reason: status[2].to_s)
          end
        end
      end
    end

    # Server-side BAG record (DETECTION-ONLY): the client pushes the whole bag as an
    # absolute {item_id => qty} snapshot. Serialized per account on the SAME mailbox
    # as :econ/:save (no read-modify-write race). We record + structurally flag, then
    # ALWAYS ack (never reject/roll back) — the bag stays blob-authoritative in M2.3.
    def handle_inv(conn, env, account_id)
      bag = env[:bag]
      seq = env[:seq]
      @mailbox.submit(account_id) do
        status = @inventory.apply_inv(account_id, bag, seq)
        @reactor.post { reply(conn, type: :inv_ack, seq: seq, flagged: status[1].any?) }
      end
    end

    # Canonical primitives the client reconciles onto its save at load (login_ok /
    # auth_ok), plus the per-channel seq the client adopts as its next-seq authority.
    # inv carries only the seq: the bag is not shipped (reconcile is server-side).
    def reconcile_block(account_id)
      snap = @ledger.snapshot(account_id)
      { econ: snap[:balances], econ_seq: snap[:last_seq],
        inv_seq: @inventory.snapshot(account_id)[:last_seq] }
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

    # Relay an addressed frame to ONLY the :to account's connection, re-stamping
    # :from with the server-trusted sender id and preserving the opaque body
    # (e.g. a battle team). Unknown/offline or self-addressed -> dropped.
    def handle_addressed(sender, env, body, from_account)
      target = @online[env[:to]]
      if target.nil? || target.equal?(sender)
        @log.call("server: no route for #{env[:type].inspect} -> #{env[:to].inspect}")
        return
      end

      @reactor.send_frame(target, Wire.encode_split(env.merge(from: from_account), body))
    end

    def bind(conn, account_id)
      # A reconnect on a new socket takes over routing for the account.
      previous = @online[account_id]
      previous.closing = true if previous && !previous.equal?(conn)
      conn.data[:account_id] = account_id
      @online[account_id] = conn
      @log.call("server: authed #{conn.addr} as account #{account_id}")
    end

    def reply(conn, **env)
      @reactor.send_frame(conn, Wire.encode_split(env))
    end

    def reply_body(conn, env, body)
      @reactor.send_frame(conn, Wire.encode_split(env, body))
    end

    def on_close(conn)
      aid = conn.data[:account_id]
      @online.delete(aid) if aid && @online[aid].equal?(conn)

      map = conn.data[:map_id]
      return unless map

      @zones[map].delete(conn)
      broadcast_zone(map, conn, Wire.encode_split({ type: :leave, id: aid })) if aid
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { @reactor.stop } }
    end
  end
end
