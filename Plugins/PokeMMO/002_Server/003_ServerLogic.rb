#===============================================================================
# PokeMMO :: ServerLogic  (host side)
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
module PokeMMO
  module ServerLogic
    @conn_account = {}   # relay connection id => account (trainer) id

    def self.account?(type)
      Config::ACCOUNT_TYPES.include?(type)
    end

    # Called by RelayServer for a decoded account message from connection +conn_id+.
    def self.handle(server, conn_id, msg)
      case msg[:type]
      when :login
        acct = msg[:account_id]
        acct = ServerStore.new_account_id if !acct.is_a?(Integer) || acct <= 0
        @conn_account[conn_id] = acct
        state = ServerStore.load_state(acct)
        server.send_to(conn_id, { :type => :login_ok, :account_id => acct, :state => state })
        PokeMMO.log("server: login conn=#{conn_id} account=#{acct} state=#{state ? 'loaded' : 'new'}")
      when :save
        acct = @conn_account[conn_id]
        return unless acct
        ok = ServerStore.save_state(acct, msg[:state])
        PokeMMO.log("server: save account=#{acct} -> #{ok}")
      end
    rescue => e
      PokeMMO.log("ServerLogic error (#{msg && msg[:type]}): #{e.class}: #{e.message}")
    end

    def self.forget(conn_id)
      @conn_account.delete(conn_id)
    end
  end
end
