#===============================================================================
# PEMK :: Auth  (client side)
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
module PEMK
  module Auth
    ACCOUNT_FILE       = "mmo_account.dat"
    GUEST_ACCOUNT_FILE = "mmo_account_guest.dat"

    @account_id       = nil
    @pending_state    = nil
    @pending_econ     = nil
    @pending_inv      = nil
    @pending_mon_evict = nil
    @logged_in        = false

    def self.account_id;    @account_id;    end
    def self.pending_state; @pending_state; end
    def self.logged_in?;    @logged_in;     end
    def self.clear_pending; @pending_state = nil; end

    # PEMK_GUEST makes this instance a distinct, PERSISTENT second player on
    # the same PC: it uses its own account file (so it never collides with the
    # main player's id), but it still saves/loads it — so the guest keeps its own
    # progress across launches instead of restarting a new game every time.
    def self.guest?
      !ENV["PEMK_GUEST"].to_s.strip.empty?
    end

    def self.account_file
      guest? ? GUEST_ACCOUNT_FILE : ACCOUNT_FILE
    end

    def self.load_local_account
      p = File.expand_path(account_file)
      return nil unless File.file?(p)
      Integer(File.read(p).strip)
    rescue
      nil
    end

    def self.save_local_account(id)
      File.write(File.expand_path(account_file), id.to_s)
    rescue => e
      PEMK.log("auth: cannot persist #{account_file}: #{e.class}: #{e.message}")
    end

    def self.mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue
      0.0
    end

    # Blocking handshake against the dedicated server. Always returns true (any
    # failure => offline/solo play proceeds). Order: (1) config email+password dev
    # shortcut, (2) a stored session token, (3) the interactive in-game screen.
    def self.login_blocking
      return true if @logged_in
      PEMK.ensure_started
      c = PEMK.client
      unless c && c.connected?
        PEMK.log("auth: no server at boot, playing offline/solo")
        # The MOST COMMON offline path — must warn too (queued; shows once in-world).
        if PEMK.enabled?
          (PEMK::NetStatus.notify(:offline, _INTL("Playing OFFLINE — your progress will NOT be saved to the server.")) rescue nil)
        end
        return true
      end

      st    = PEMK.settings
      email = st[:email].to_s
      pw    = st[:password].to_s

      if !email.empty? && !pw.empty?
        config_login(c, email, pw)            # dev shortcut: the configured account
      elsif (token = load_token) && try_auth(c, token)
        # reconnected as the last account via its saved session token
      else
        PEMK::AuthUI.run(c)                    # players: log in / create account in-game
      end
      unless @logged_in
        # Playing without a server session: keep vanilla semantics, but say so —
        # a silent offline session used to be destroyed at the next login.
        (PEMK::NetStatus.notify(:offline, _INTL("Playing OFFLINE — your progress will NOT be saved to the server.")) rescue nil)
      end
      true
    end

    # Non-interactive login for the mmo_config.txt dev shortcut: log in the
    # configured email, registering it first if it does not exist yet.
    def self.config_login(c, email, pw)
      reply = send_and_wait(c, { :type => :login, :email => email, :password => pw }, [:login_ok, :login_err])
      if reply && reply[:type] == :login_err && reply[:reason] == "not_found"
        PEMK.log("auth: config account #{email.inspect} not found -> registering")
        reg = send_and_wait(c, { :type => :register, :email => email, :password => pw }, [:register_ok, :register_err])
        return PEMK.log("auth: config register failed (#{reg && reg[:reason]})") unless reg && reg[:type] == :register_ok

        reply = send_and_wait(c, { :type => :login, :email => email, :password => pw }, [:login_ok, :login_err])
      end
      if reply && reply[:type] == :login_ok
        apply_login(reply)
      else
        PEMK.log("auth: config login failed (#{reply && reply[:reason]})")
      end
    end

    # Reconnect with a stored session token; true on success.
    def self.try_auth(c, token)
      reply = send_and_wait(c, { :type => :auth, :token => token }, [:auth_ok, :auth_err])
      if reply && reply[:type] == :auth_ok
        apply_login(reply)
        return true
      end
      PEMK.log("auth: stored token rejected -> password login")
      false
    end

    # Adopt a successful login_ok / auth_ok: identity, session token, and the
    # server-held save (an opaque body the client Marshal-loads — its own data).
    #
    # ANTI-WIPE GUARD: an UNDECODABLE server blob (format/class drift after an
    # update, truncation) must NOT be treated like a fresh account — that silent
    # fallback used to run Game.start_new and the first checkpoint then destroyed
    # the (possibly recoverable) server blob AND the local save within minutes.
    # A present-but-corrupt body refuses the login: offline session, loud message,
    # the server blob stays untouched for operator recovery.
    def self.apply_login(reply)
      raw   = reply[:_body]
      state = nil
      if raw
        state = (Marshal.load(raw) rescue :__corrupt__)
        state = :__corrupt__ unless state.is_a?(Hash)
      end
      if state == :__corrupt__
        PEMK.log("auth: server save for account #{reply[:account_id]} is UNDECODABLE -> refusing login (anti-wipe)")
        (PEMK::NetStatus.notify(:corrupt, _INTL("Your online save could not be loaded (version mismatch?). Playing OFFLINE to protect your data — please contact the server operator.")) rescue nil)
        (PEMK.shutdown rescue nil)
        @pending_state = nil
        @logged_in     = false
        return false
      end

      @account_id    = reply[:account_id]
      @pending_state = state
      @pending_econ  = reply[:econ].is_a?(Hash) ? reply[:econ] : nil
      @pending_inv   = reply[:inv].is_a?(Hash) ? reply[:inv] : nil  # nil = unseeded (keep blob bag)
      @pending_mon_evict = reply[:mon_evict]                        # uids traded away (M3.2) -> evict at load
      @logged_in     = true
      PEMK.set_self_id(@account_id)
      (PEMK::Sync.reset rescue nil)                          # fresh socket -> drop stale dirty/seq baseline
      (PEMK::Sync.adopt_econ_seq(reply[:econ_seq]) rescue nil) # ... then adopt the server's seq authority
      (PEMK::Sync.adopt_inv_seq(reply[:inv_seq]) rescue nil)  # ... same for the independent :inv channel
      (PEMK::Sync.adopt_mon_seq(reply[:mon_seq]) rescue nil)  # ... and the :mon_party projection channel
      (PEMK::Pickup.adopt_enforce(reply[:pickup_enforce]) rescue nil)  # M4-C: gate pickups only if server says on
      (PEMK::Pickup.adopt_reset_allowed(reply[:pickup_reset_allowed]) rescue nil)  # M4-C: dev-only F9 reset
      (PEMK::Encounter.adopt_mode(reply[:battle_enforce_encounters]) rescue nil)   # M4-D2: encounter mode
      (PEMK::Catch.adopt_mode(reply[:battle_enforce_catches]) rescue nil)          # M4-D3: catch mode
      save_token(reply[:token]) if reply[:token]
      save_local_account(@account_id)
      PEMK.log("auth: #{reply[:type]} account=#{@account_id} state=#{@pending_state ? 'received' : 'new'} econ=#{@pending_econ ? @pending_econ.size : 0}")
      true
    end

    # Mid-session re-auth after a reconnect (NetStatus FSM). Deliberately does NOT
    # hydrate pending_state/econ/inv — restoring server state onto a LIVE player
    # would rewind them; the client re-seeds the server instead (absolute values).
    # -> :ok | :auth_err (token unusable, retrying can never work) | :net (retry)
    def self.relogin(c)
      token = load_token
      return :auth_err unless token && @account_id   # nothing to retry with

      reply = send_and_wait(c, { :type => :auth, :token => token }, [:auth_ok, :auth_err], 3.0)
      return :net unless reply                        # timeout / transport — retry
      return :auth_err unless reply[:type] == :auth_ok && reply[:account_id] == @account_id

      PEMK.set_self_id(@account_id)
      (PEMK::Sync.reset rescue nil)
      (PEMK::Sync.adopt_econ_seq(reply[:econ_seq]) rescue nil)
      (PEMK::Sync.adopt_inv_seq(reply[:inv_seq]) rescue nil)
      (PEMK::Sync.adopt_mon_seq(reply[:mon_seq]) rescue nil)
      (PEMK::Pickup.adopt_enforce(reply[:pickup_enforce]) rescue nil)  # M4-C
      (PEMK::Pickup.adopt_reset_allowed(reply[:pickup_reset_allowed]) rescue nil)  # M4-C: dev-only F9 reset
      (PEMK::Encounter.adopt_mode(reply[:battle_enforce_encounters]) rescue nil)   # M4-D2: encounter mode
      (PEMK::Catch.adopt_mode(reply[:battle_enforce_catches]) rescue nil)          # M4-D3: catch mode
      :ok
    end

    # Abandon a login whose state cannot be used (undecodable/unmigratable blob):
    # back to a clean offline session, the server blob untouched.
    def self.abort_login!
      @logged_in     = false
      @pending_state = nil
      @pending_econ  = nil
      @pending_inv   = nil
    end

    # After a successful mid-session reconnect: the server may have missed up to a
    # whole disconnected stretch. Every T1 channel is an ABSOLUTE value, so a
    # client-wins re-seed is one mark per channel; the blob re-pushes force:true
    # (Sync.reset cleared the content hash, so it always sends once).
    def self.reseed_after_reconnect
      return unless $player

      (PEMK::Sync.mark_econ(:money, $player.money) rescue nil)
      (PEMK::Sync.mark_econ(:coins, $player.coins) rescue nil)
      (PEMK::Sync.mark_econ(:battle_points, $player.battle_points) rescue nil)
      (PEMK::Sync.mark_econ(:soot, $player.soot) rescue nil)
      begin
        mask = 0
        $player.badges.each_with_index { |v, i| mask |= (1 << i) if v && i < PEMK::BADGE_BITS }
        PEMK::Sync.mark_econ(:badges, mask)
      rescue StandardError
        nil
      end
      (PEMK::Sync.mark_inv rescue nil)
      (PEMK::Sync.mark_mon rescue nil)
      (PEMK::Sync.push_blob(SaveData::FILE_PATH, force: true) rescue nil)
    end

    # Reconcile the ledger's canonical economy onto $player once the world exists
    # (called from Game.load / Game.start_new after apply_identity). The economy is
    # server-owned, so the ledger snapshot overrides whatever the loaded blob held.
    # Applied through the trusted, non-notifying setter so it never echoes back.
    # Consumed once: a new account's snapshot is empty and this is a no-op.
    def self.reconcile_economy
      econ = @pending_econ
      @pending_econ = nil
      return unless econ.is_a?(Hash) && $player

      # Per-field rescue (NOT one outer rescue): economy_balances row order can put
      # :badges first, and a badge-decode fault must never skip the authoritative
      # money reconcile for the fields after it. :badges is a bitmask -> decode it.
      econ.each do |field, value|
        next unless value.is_a?(Integer)
        begin
          if field.to_sym == :badges
            $player.pokemmo_apply_badges_mask(value)
          else
            $player.pokemmo_apply_economy(field.to_sym, value)
          end
        rescue => e
          PEMK.log("auth: reconcile field #{field} error: #{e.class}: #{e.message}")
        end
      end
    end

    # Restore the bag from the server (server-persistent, like the economy). A
    # SEEDED record (a Hash, even {}) is authoritative and overwrites $bag; an
    # UNSEEDED account (nil) keeps its blob bag and seeds the record on the first
    # flush. Runs at load AFTER the blob populated $bag (see PersistHooks).
    def self.reconcile_inventory
      inv = @pending_inv
      @pending_inv = nil
      if inv.is_a?(Hash)
        PEMK::Inventory.apply_bag(inv)                 # authoritative overwrite
      else
        (PEMK::Inventory.capture_on_load rescue nil)   # unseeded -> seed from the blob bag
      end
    rescue => e
      PEMK.log("auth: reconcile_inventory error: #{e.class}: #{e.message}")
    end

    # Monster reconcile at load. FIRST evict uids this account traded away and no
    # longer owns (M3.2 enforcement — a possibly-stale blob may still show them),
    # THEN mark the :mon channel so the sweep mints any new mons and the first
    # party projection reflects the post-eviction party. Positive list only — an
    # absent/empty mon_evict never removes anything.
    def self.reconcile_monsters
      if @pending_mon_evict.is_a?(Array) && !@pending_mon_evict.empty?
        (PEMK::Monsters.evict(@pending_mon_evict) rescue nil)
      end
      @pending_mon_evict = nil
      (PEMK::Sync.mark_mon rescue nil)
    end

    # Send a message and block for one of +types+, pumping the client WITHOUT
    # touching Graphics.update (which blows mkxp-z's stack at the load screen).
    def self.send_and_wait(c, msg, types, timeout = Config::LOGIN_TIMEOUT)
      c.send_message(msg)
      deadline = mono + timeout
      while mono < deadline
        sleep(0.01)
        c.poll.each { |m| return m if m.is_a?(Hash) && types.include?(m[:type]) }
        return nil unless c.connected?
      end
      nil
    end

    def self.token_file
      guest? ? "mmo_session_guest.dat" : "mmo_session.dat"
    end

    # The saved session token is the LAST logged-in account. It is only consulted
    # when there are no config credentials (those take priority and override it),
    # so no per-account binding is needed here.
    def self.load_token
      path = File.expand_path(token_file)
      return nil unless File.file?(path)

      tok = File.read(path).strip
      tok.empty? ? nil : tok
    rescue
      nil
    end

    def self.save_token(token)
      File.write(File.expand_path(token_file), token.to_s)
    rescue => e
      PEMK.log("auth: cannot persist token: #{e.class}: #{e.message}")
    end

    # Stamp the server-issued identity onto $player (overrides the random id).
    def self.apply_identity
      return unless @account_id.is_a?(Integer) && $player
      $player.id = @account_id & 0xFFFFFFFF   # Trainer#id is attr_accessor
    rescue => e
      PEMK.log("auth: apply_identity error: #{e.class}: #{e.message}")
    end
  end
end
