#===============================================================================
# PokeMMO :: Auth  (client side)
#-------------------------------------------------------------------------------
# The blocking login performed at the New Game / Continue crossroads (before the
# player enters the world). It:
#   - connects (ensure_started),
#   - sends :login with our persisted account id (mmo_account.dat, or nil the
#     first time),
#   - waits for :login_ok, keeping mkxp-z alive (Graphics/Input update) AND
#     pumping our own relay if we host (the frame pump doesn't run at the load
#     screen), with a timeout that degrades to offline/solo,
#   - remembers the server-issued account id (= our stable trainer id + presence
#     id) and the server's stored state to hydrate.
#===============================================================================
module PokeMMO
  module Auth
    ACCOUNT_FILE = "mmo_account.dat"

    @account_id    = nil
    @pending_state = nil
    @logged_in     = false

    def self.account_id;    @account_id;    end
    def self.pending_state; @pending_state; end
    def self.logged_in?;    @logged_in;     end
    def self.clear_pending; @pending_state = nil; end

    def self.load_local_account
      p = File.expand_path(ACCOUNT_FILE)
      return nil unless File.file?(p)
      Integer(File.read(p).strip)
    rescue
      nil
    end

    def self.save_local_account(id)
      File.write(File.expand_path(ACCOUNT_FILE), id.to_s)
    rescue => e
      PokeMMO.log("auth: cannot persist #{ACCOUNT_FILE}: #{e.class}: #{e.message}")
    end

    def self.mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue
      0.0
    end

    # Blocking handshake. Always returns true (offline => solo play proceeds).
    def self.login_blocking
      return true if @logged_in
      PokeMMO.ensure_started
      c = PokeMMO.client
      unless c && c.connected?
        PokeMMO.log("auth: no server, playing offline/solo")
        return true
      end
      # Guest mode (POKEMMO_GUEST env var): use a fresh server-assigned account,
      # not the persisted one — lets two instances on ONE PC be distinct players.
      guest = !ENV["POKEMMO_GUEST"].to_s.strip.empty?
      @account_id ||= load_local_account unless guest
      c.send_message({ :type => :login, :account_id => @account_id })
      PokeMMO.log("auth: sent :login (account=#{@account_id.inspect}#{guest ? ' GUEST' : ''}), waiting")
      deadline = mono + Config::LOGIN_TIMEOUT
      while mono < deadline
        # Do NOT call Graphics.update here: driving it manually from inside the
        # load screen blows mkxp-z's stack. A short sleep yields the GVL so the
        # acceptor thread runs and the relay pump processes our login; localhost
        # login is near-instant so there is no visible freeze.
        sleep(0.005)
        r = PokeMMO.relay
        r.pump if r                      # host: process our own login (no frame pump yet)
        done = false
        c.poll.each do |m|
          next unless m.is_a?(Hash) && m[:type] == :login_ok
          @account_id    = m[:account_id]
          @pending_state = m[:state]
          @logged_in     = true
          save_local_account(@account_id) unless guest
          PokeMMO.set_self_id(@account_id)   # account id becomes our presence id
          PokeMMO.log("auth: login_ok account=#{@account_id} state=#{m[:state] ? 'received' : 'new'}")
          done = true
          break
        end
        return true if done
      end
      PokeMMO.log("auth: login timed out, proceeding offline")
      true
    end

    # Stamp the server-issued identity onto $player (overrides the random id).
    def self.apply_identity
      return unless @account_id.is_a?(Integer) && $player
      $player.id = @account_id & 0xFFFFFFFF   # Trainer#id is attr_accessor
    rescue => e
      PokeMMO.log("auth: apply_identity error: #{e.class}: #{e.message}")
    end
  end
end
