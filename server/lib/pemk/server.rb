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
                        battle_start battle_choice battle_round battle_switch battle_end
                        trade_invite trade_accept trade_decline trade_offer trade_lock trade_cancel].freeze
    TRADE_TTL      = 15          # seconds a half-committed (lone) trade rendezvous lingers before timeout
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
      @monsters   = Monsters.new(@db, @config.monster_caps, logger: @log)
      @trades     = Trades.new(@db)
      # M4 Layer A: read-only world model + detection-only interaction audit. Both are
      # in-memory and DB-free; a missing export just makes the audit a no-op.
      @world      = WorldData.new(@config.world_path, logger: @log)
      @audit      = Audit.new(@world, logger: @log)
      @pos_audit  = PositionAudit.new(@world, logger: @log, mode: @config.position_enforcement)   # M4 Layer B
      @pickups    = Pickups.new(@db)   # M4 Layer C one-shot ledger
      @pool     = WorkerPool.new(size: WORKERS, logger: @log)
      @limiter  = RateLimiter.new(max: LOGIN_MAX, per: LOGIN_WINDOW)
      @zones    = Hash.new { |h, k| h[k] = Set.new }   # map_id => Set(conn); reactor-thread only
      @online   = {}                                    # account_id => conn; reactor-thread only
      @pending_trades = {}                              # trade_id => rendezvous; reactor-thread only
      @reactor  = Reactor.new(
        host: @config.bind, port: @config.port,
        on_frame: method(:on_frame), on_close: method(:on_close),
        on_tick: method(:sweep_trades), logger: @log
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
      @log.call("server: monster caps #{@config.monster_caps} (uid registry, flag-not-reject)")
      @log.call("server: world data #{@world.summary} (M4 Layer A, audit-only)")
      @log.call("server: position enforcement = #{@config.position_enforcement} (M4 Layer B)")
      @log.call("server: pickup enforcement = #{@config.pickup_enforce ? 'on' : 'off'} (M4 Layer C server-mint)")
      @log.call("server: WARNING pickup reset ALLOWED (PEMK_ALLOW_PICKUP_RESET=on) — DEV ONLY, disable in production") if @config.pickup_reset_allowed
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
      when :save     then handle_save(env, dec[:body], authed, conn.data[:last_pos])
      when :econ     then handle_econ(conn, env, authed)
      when :inv      then handle_inv(conn, env, authed)
      when :uid_req  then handle_uid_req(conn, env, authed)
      when :mon_party then handle_mon_party(conn, env, authed)
      when :interact_claim then handle_interact_claim(conn, env, authed)
      when :pickup_req then handle_pickup_req(conn, env, authed)
      when :pickups_reset then handle_pickups_reset(conn, env, authed)
      when :trade_commit then handle_trade_commit(conn, env, authed)
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
          # The state READ must serialize behind any in-flight :save/:econ/:inv for
          # this account (a login racing a pending save would hand back a stale
          # blob and the client's next push would fossilize the rollback). Mailbox
          # bookkeeping is reactor-thread-only, so route the submit through post.
          @reactor.post do
            @mailbox.submit(acct[:id]) do
              blob = @characters.load_blob(acct[:id])   # opaque; never loaded here
              rec  = reconcile_block(acct[:id])
              pos  = (@characters.load_position(acct[:id]) rescue nil)   # M4-B: seed last_pos (never brick login)
              @reactor.post do
                if @reactor.alive?(conn)   # never bind a dead conn into @online
                  bind(conn, acct[:id])
                  conn.data[:last_pos] = pos if pos
                  reply_body(conn, { type: :login_ok, account_id: acct[:id], token: token }.merge(rec), blob)
                end
              end
            end
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
          # Same serialization as handle_login: read behind the account's mailbox.
          @reactor.post do
            @mailbox.submit(account_id) do
              blob = @characters.load_blob(account_id)
              rec  = reconcile_block(account_id)
              pos  = (@characters.load_position(account_id) rescue nil)   # M4-B: seed last_pos (never brick login)
              @reactor.post do
                if @reactor.alive?(conn)   # never bind a dead conn into @online
                  bind(conn, account_id)
                  conn.data[:last_pos] = pos if pos
                  reply_body(conn, { type: :auth_ok, account_id: account_id }.merge(rec), blob)
                end
              end
            end
          end
        else
          @reactor.post { reply(conn, type: :auth_err, reason: "invalid_token") }
        end
      end
    end

    # Persist the opaque save body (never Marshal.load'd server-side). On the
    # per-account MAILBOX (not the raw pool): two rapid pushes for one account
    # must commit in arrival order (raw-pool scheduling could commit the OLDER
    # blob last, silently rolling the account back), and the login/auth state
    # read serializes behind any in-flight save.
    def handle_save(env, body, account_id, last_pos)
      unless body.is_a?(String) && !body.empty?
        @log.call("server: empty :save from account #{account_id} -> ignore")
        return
      end

      tid = env[:trainer_id]
      sv  = env[:save_version]
      wv  = env[:wire_version]
      # Persist the SERVER-tracked position (captured on the reactor thread when the
      # frame arrived, not client-claimed) alongside the blob, so the next login seeds
      # the position audit. nil (no presence yet) leaves the stored position untouched.
      @mailbox.submit(account_id) do
        @characters.store(account_id, blob: body, trainer_id: tid, save_version: sv, wire_version: wv, position: last_pos)
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

    # Server-issued monster UIDs (M3.1): mint one uid per swept instance, matched by
    # the client's persisted nonce. Idempotent by the monsters_mint_dedup unique
    # index — a replayed request re-receives the SAME uids. On the mailbox like all
    # per-account mutations.
    def handle_uid_req(conn, env, account_id)
      mons = env[:mons]
      seq  = env[:seq]
      @mailbox.submit(account_id) do
        status = @monsters.mint_batch(account_id, mons)
        if status.first == :ack
          @reactor.post { reply(conn, type: :uid_grant, grants: status[1], seq: seq) }
        else
          @log.call("server: bad :uid_req from account #{account_id} -> ignored")
        end
      end
    end

    # Party projection (detection-only shadow): record + cross-check against the
    # registry, FLAG never reject, always ack.
    def handle_mon_party(conn, env, account_id)
      mons = env[:mons]
      seq  = env[:seq]
      @mailbox.submit(account_id) do
        status = @monsters.apply_party(account_id, mons, seq)
        @reactor.post { reply(conn, type: :mon_ack, seq: seq, flagged: status[1].any?) }
      end
    end

    # Detection-only interaction audit (M4 Layer A). Runs INLINE on the reactor
    # thread like handle_presence — no mailbox, no DB, and crucially NO reply: it is
    # pure telemetry. Compares the client's interaction claim against the read-only
    # world model and logs a mismatch; it enforces nothing (enforcement is a later
    # layer). Identity is the server-trusted account_id, never a client :id.
    def handle_interact_claim(conn, env, account_id)
      # Layer C: judge the pickup against the player's SERVER-tracked tile (Layer B),
      # not the client-claimed px/py — so a remote pickup is caught. Inline + cheap.
      verdict = @audit.check_interaction(account_id, env, conn.data[:last_pos])

      # Layer C one-shot: a VALID item-ball pickup is recorded per account; a repeat
      # claim for the same tile is a dupe. The DB write goes on the per-account mailbox
      # so it never blocks the reactor. (Gifts have no fixed tile — skip them.)
      return unless verdict == :match && env[:kind] == :item

      map = env[:map]; x = env[:x]; y = env[:y]
      return unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      item = env[:item]
      @mailbox.submit(account_id) do
        if @pickups.record(account_id, map, x, y) == :dup
          @log.call("audit: account #{account_id} already_taken item=#{item.to_s[0, 32]} at (#{map},#{x},#{y})")
        end
      end
    end

    # Server-minted pickup (M4 Layer C): the client asks permission BEFORE adding an
    # item ball; we validate and reply :pickup_grant / :pickup_deny. Existence + item
    # + distance are judged INLINE against the world model and the player's SERVER-
    # tracked tile (never client px/py); the one-shot is then done ATOMICALLY on the
    # per-account mailbox (record -> :new grants, :dup denies), so two rapid requests
    # for one tile can never both grant. Fail-OPEN when no world is exported (an
    # operator misconfig must not brick every pickup); fail-CLOSED on any real reject.
    def handle_pickup_req(conn, env, account_id)
      seq = env[:seq]
      map = env[:map]; x = env[:x]; y = env[:y]

      verdict = @audit.check_interaction(account_id, env, conn.data[:last_pos])

      if verdict == :unchecked
        @log.call("pickup: account #{account_id} GRANT (world unexported — fail-open) seq=#{seq.inspect}")
        return reply(conn, type: :pickup_grant, seq: seq, item: env[:item], map: map, x: x, y: y)
      end
      unless verdict == :match
        return reply(conn, type: :pickup_deny, seq: seq, reason: verdict.to_s)
      end

      obj  = @world.object_at(map, x, y)
      item = (obj && obj["item"]) || env[:item]   # server-authoritative item id
      @mailbox.submit(account_id) do
        status = @pickups.record(account_id, map, x, y)
        @reactor.post do
          next unless @reactor.alive?(conn)

          if status == :new
            reply(conn, type: :pickup_grant, seq: seq, item: item, map: map, x: x, y: y)
          else
            reply(conn, type: :pickup_deny, seq: seq, reason: "already_taken")
          end
        end
      end
    end

    # DEV/QA-ONLY pickup reset (M4 Layer C polish). Forgets this account's taken tiles
    # so its item balls can be re-tested. Fail-CLOSED: honored ONLY when the server was
    # booted with PEMK_ALLOW_PICKUP_RESET=on. In production that flag is off, so this
    # always denies — a client could otherwise wipe its pickups and re-farm every item
    # ball infinitely. The client's F9 tool only offers the reset when reconcile_block
    # advertised it, but we re-check the server flag here (never trust the client).
    def handle_pickups_reset(conn, env, account_id)
      seq = env[:seq]
      unless @config.pickup_reset_allowed
        @log.call("pickup-reset: account #{account_id} DENIED (PEMK_ALLOW_PICKUP_RESET off)")
        return reply(conn, type: :pickups_reset_deny, seq: seq, reason: "not_allowed")
      end

      @mailbox.submit(account_id) do
        n = @pickups.clear(account_id)
        @reactor.post do
          next unless @reactor.alive?(conn)

          @log.call("pickup-reset: account #{account_id} cleared #{n} tile(s) (DEV)")
          reply(conn, type: :pickups_reset_ok, seq: seq, cleared: n)
        end
      end
    end

    # Server-authoritative trade COMMIT (M3.2). The only authoritative trade frame
    # (invite/accept/offer/lock/cancel are pure peer relay via ADDRESSED). Each side
    # commits ONLY after it holds the partner's uid-validated object; the server
    # rendezvous fires the atomic swap when BOTH matching commits arrive.
    def handle_trade_commit(conn, env, account_id)
      trade_id = env[:trade_id]
      partner  = env[:partner]
      give     = env[:give]
      recv     = env[:recv]
      max      = @config.monster_caps[:trade_max]
      unless trade_id.is_a?(String) && partner.is_a?(Integer) && partner != account_id &&
             uid_list?(give, max) && uid_list?(recv, max)
        @log.call("server: bad :trade_commit from account #{account_id} -> drop")
        return
      end
      give = give.sort
      recv = recv.sort

      pending = @pending_trades[trade_id]
      if pending.nil?
        @pending_trades[trade_id] = { account: account_id, partner: partner,
                                      give: give, recv: recv, conn: conn, at: Time.now }
        return
      end

      @pending_trades.delete(trade_id)
      # Cross-check the two commits name each other and mirror give/recv exactly. A
      # third party guessing a trade_id fails here (its partner id won't match).
      unless pending[:account] == partner && pending[:partner] == account_id &&
             pending[:give] == recv && pending[:recv] == give
        reply(conn, type: :trade_result, trade_id: trade_id, ok: false, reason: "terms")
        reply(pending[:conn], type: :trade_result, trade_id: trade_id, ok: false, reason: "terms")
        return
      end

      a = pending[:account]; a_conn = pending[:conn]; a_gives = pending[:give]
      b = account_id;        b_conn = conn;           b_gives = give
      @pool.submit do
        st = @trades.execute_trade(trade_id, a: a, b: b, a_gives: a_gives, b_gives: b_gives)
        @reactor.post do
          if st.first == :ok || st.first == :ok_replay
            reply(a_conn, type: :trade_result, trade_id: trade_id, ok: true, recv: b_gives, gave: a_gives) if @reactor.alive?(a_conn)
            reply(b_conn, type: :trade_result, trade_id: trade_id, ok: true, recv: a_gives, gave: b_gives) if @reactor.alive?(b_conn)
            @log.call("server: trade #{trade_id} #{a}<->#{b} swapped #{a_gives}/#{b_gives}")
          else
            reason = st[1].to_s
            reply(a_conn, type: :trade_result, trade_id: trade_id, ok: false, reason: reason) if @reactor.alive?(a_conn)
            reply(b_conn, type: :trade_result, trade_id: trade_id, ok: false, reason: reason) if @reactor.alive?(b_conn)
          end
        end
      end
    end

    def uid_list?(a, max)
      a.is_a?(Array) && a.size.between?(1, max) && a.all? { |u| u.is_a?(Integer) && u.positive? }
    end

    # Reactor-thread periodic: time out a lone (half-committed) rendezvous whose
    # partner never committed and never disconnected. A lone commit never mutated
    # the registry, so this only frees the entry + tells the waiter.
    def sweep_trades
      return if @pending_trades.empty?

      now = Time.now
      @pending_trades.reject! do |tid, p|
        next false if (now - p[:at]) < TRADE_TTL

        reply(p[:conn], type: :trade_result, trade_id: tid, ok: false, reason: "timeout") if @reactor.alive?(p[:conn])
        true
      end
    end

    # Canonical primitives the client reconciles onto its save at load (login_ok /
    # auth_ok), plus the per-channel seq the client adopts as its next-seq authority.
    # inv carries the whole bag (server-persistent, like economy): nil when unseeded
    # so the client keeps its blob bag and seeds the record on the first flush.
    # mon_seq is the :mon_party high-water; mon_evict is the M3.2 positive list of
    # uids this account traded away and no longer owns (the client evicts them).
    def reconcile_block(account_id)
      snap = @ledger.snapshot(account_id)
      inv  = @inventory.snapshot(account_id)
      { econ: snap[:balances], econ_seq: snap[:last_seq],
        inv: inv[:bag], inv_seq: inv[:last_seq],
        mon_seq: @monsters.mon_seq(account_id),
        mon_evict: @monsters.evictions(account_id),
        pickup_enforce: @config.pickup_enforce,     # M4 Layer C: client gates pickups only when on
        pickup_reset_allowed: @config.pickup_reset_allowed }   # dev-only F9 reset offered only when on
    end

    # Zone-scoped presence: track each player's current map and fan a position
    # update out ONLY to same-map connections (the 500-CCU lever). Runs inline on
    # the reactor thread — cheap, in-memory, no DB. Identity is the server-trusted
    # account_id, not the client-provided :id (anti-spoof).
    def handle_presence(conn, env, account_id)
      map = env[:map]
      return unless map.is_a?(Integer)

      # M4 Layer B: audit FIRST. In :on mode an enforceable violation stashes the
      # last-good tile in conn.data[:correct_to] — send a :pos_correct and REJECT the
      # frame: no zone change and no fan-out of the rejected position, so peers keep
      # seeing the offender at its last accepted tile and it never joins the illegal
      # map's zone. In :off/:shadow correct_to is never set, so the frame flows on.
      @pos_audit.check(account_id, env, conn.data)
      if (tgt = conn.data.delete(:correct_to))
        reply(conn, type: :pos_correct, map: tgt[0], x: tgt[1], y: tgt[2])
        return
      end

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
      cancel_pending_trades(aid, conn) if aid

      map = conn.data[:map_id]
      return unless map

      @zones[map].delete(conn)
      broadcast_zone(map, conn, Wire.encode_split({ type: :leave, id: aid })) if aid
    end

    # A dropped account cancels any rendezvous it was part of. If a LONE committer
    # (the still-connected party) was waiting on this account, tell it "partner_left"
    # — a single commit never mutated the registry, so nothing was traded.
    def cancel_pending_trades(aid, closing_conn)
      @pending_trades.reject! do |tid, p|
        next false unless p[:account] == aid || p[:partner] == aid

        waiter = p[:conn]
        if !waiter.equal?(closing_conn) && @reactor.alive?(waiter)
          reply(waiter, type: :trade_result, trade_id: tid, ok: false, reason: "partner_left")
        end
        true
      end
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { @reactor.stop } }
    end
  end
end
