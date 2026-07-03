#===============================================================================
# PEMK :: ServerLogic  (host side)
#-------------------------------------------------------------------------------
# Handles the authoritative account messages the RelayServer routes to it
# (everything not in Config::ACCOUNT_TYPES is relayed to other clients instead).
#
#   :login {account_id?} -> assign/keep a trainer id, load that account's stored
#                           state, reply :login_ok {account_id, state} to sender.
#   :save  {state}       -> persist the sender's account state to disk.
#
# TRUST: this is the "host + friends" model — a client's claimed account_id is
# honoured (impersonation is possible on a hostile LAN). Real authentication is a
# later hardening step (architecture doc §5.6 / §10). The host also Marshal-loads
# client messages here, the same trust boundary the clients already accept.
#===============================================================================
module PEMK
  module ServerLogic
    @conn_account = {}   # relay connection id => account (trainer) id
    @account_conn = {}   # account (trainer) id => relay connection id (reverse of
                         # the above, so the relay can route a :to-addressed frame
                         # to that one recipient instead of broadcasting it)

    def self.account?(type)
      Config::ACCOUNT_TYPES.include?(type)
    end

    # Called by RelayServer for a decoded account envelope from connection
    # +conn_id+. +body+ is the frame's opaque body (raw bytes) when present — used
    # by :save so the host stores the save without Marshal.loading its graph.
    def self.handle(server, conn_id, msg, body = nil)
      case msg[:type]
      when :login
        acct = msg[:account_id]
        acct = ServerStore.new_account_id if !acct.is_a?(Integer) || acct <= 0
        bind_account(conn_id, acct)
        # State travels back as an opaque body; the host never Marshal.loads it —
        # the owning client reconstructs its own state.
        state = ServerStore.load_state(acct)   # raw bytes or nil
        server.send_to(conn_id, { :type => :login_ok, :account_id => acct }, state)
        PEMK.log("server: login conn=#{conn_id} account=#{acct} state=#{state ? 'loaded' : 'new'}")
      when :save
        acct = @conn_account[conn_id]
        return unless acct
        # The save graph rides in the opaque body; the host writes it verbatim and
        # never Marshal.loads it (no RCE via a hostile :save).
        ok = ServerStore.save_state(acct, body)
        PEMK.log("server: save account=#{acct} -> #{ok} (#{body ? body.bytesize : 0} bytes)")
      when :mutate
        # Economy sync + hard cap. (True anti-cheat needs server-side game logic,
        # a later phase; for now the server enforces the range and can reject.)
        field = msg[:field]
        val   = msg[:value]
        max   = field_max(field)
        return unless max && val.is_a?(Integer)
        canon = val.clamp(0, max)
        acct  = @conn_account[conn_id]
        server.send_to(conn_id, { :type => :mutate_ack, :field => field, :value => canon })
        PEMK.log("server: mutate account=#{acct} #{field}=#{val}->#{canon}")
      when :badge
        idx   = msg[:index]
        owned = msg[:owned] ? true : false
        return unless idx.is_a?(Integer) && idx >= 0 && idx < 64   # sane range
        acct = @conn_account[conn_id]
        server.send_to(conn_id, { :type => :badge_ack, :index => idx, :owned => owned })
        PEMK.log("server: badge account=#{acct} [#{idx}]=#{owned}")
      when :inv
        # Bag/box operations. Logged now (foundation/observability); server-side
        # inventory validation is a later phase, so there is no ack to apply.
        acct = @conn_account[conn_id]
        PEMK.log("server: inv account=#{acct} #{msg[:op]} item=#{msg[:item].inspect} qty=#{msg[:qty].inspect} box=#{msg[:box].inspect} index=#{msg[:index].inspect}")
      end
    rescue => e
      PEMK.log("ServerLogic error (#{msg && msg[:type]}): #{e.class}: #{e.message}")
    end

    # Hard cap per economy field (reads the game's own Settings on the host).
    def self.field_max(field)
      case field
      when :money         then (Settings::MAX_MONEY         rescue 999_999)
      when :coins         then (Settings::MAX_COINS         rescue 99_999)
      when :battle_points then (Settings::MAX_BATTLE_POINTS rescue 9_999)
      when :soot          then (Settings::MAX_SOOT          rescue 9_999)
      end
    end

    # Bind (or rebind) a connection to an account, keeping the reverse index
    # consistent: a reconnecting account moves to its new connection, and a
    # connection that re-logs under a new account releases its old reverse entry.
    def self.bind_account(conn_id, acct)
      prev = @conn_account[conn_id]
      @account_conn.delete(prev) if prev && prev != acct && @account_conn[prev] == conn_id
      @conn_account[conn_id] = acct
      @account_conn[acct]    = conn_id
    end

    # Connection currently serving +account_id+, or nil if that account is offline.
    # The relay calls this to route an addressed (:to) frame to one recipient.
    def self.conn_for(account_id)
      @account_conn[account_id]
    end

    def self.forget(conn_id)
      acct = @conn_account.delete(conn_id)
      @account_conn.delete(acct) if acct && @account_conn[acct] == conn_id
    end
  end
end
