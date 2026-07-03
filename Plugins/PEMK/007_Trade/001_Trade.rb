#===============================================================================
# PEMK :: Trade  (M3.2 client — server-authoritative Pokémon trading)
#-------------------------------------------------------------------------------
# Two players on the same map trade one Pokémon each. SECURITY is entirely
# server-side (Trades#execute_trade does the atomic dupe-proof ownership swap);
# this is the handshake + UI + escrow transport + apply/evict.
#
# Transports mirror the battle handshake:
#   - invite/accept/decline/offer/lock/cancel ride the ADDRESSED peer relay (the
#     server re-stamps a trusted :from and never decodes the opaque body);
#   - :trade_commit is the ONLY authoritative frame — it terminates at the server,
#     which fires the swap when BOTH sides' commits cross-check.
#
# Flow (both sides reach :choosing after accept):
#   choose a mon -> :trade_offer (primitive preview) -> see partner's offer ->
#   confirm -> :trade_lock (+ the REAL Pokémon as an opaque Marshal body, escrow)
#   -> once I hold the partner's uid-validated object AND I've locked -> commit.
# An honest client commits ONLY after it holds the object it will receive, so a
# withholder can never make the honest side commit (it just times out).
#
# Prompts run ONLY from update_ui on a safe overworld frame (@in_ui guard), never
# inside the network pump. Dispatch parks inbound frames into ivars.
#===============================================================================
module PEMK
  module Trade
    TIMEOUT = 30.0   # seconds a WAITING phase lingers before a local cancel

    @session = nil   # active trade (see phase machine below) or nil
    @invite  = nil   # { from, name, trade_id } — an invite to prompt about
    @notice  = nil   # a queued player message
    @in_ui   = false # re-entrancy guard for blocking prompts

    module_function

    # A trade is in progress -> suppress checkpoints and the party projection so a
    # mid-trade snapshot never flags the mon we are about to lose/gain.
    def busy?
      !@session.nil?
    end

    def reset
      @session = nil
      @invite  = nil
      @notice  = nil
    end

    def own_name
      $player ? $player.name : "?"
    end

    # --- start: from the pause-menu option --------------------------------------
    def pbTradeFromMenu
      unless PEMK.client && PEMK.client.connected?
        pbMessage(_INTL("You are not connected to a server."))
        return
      end
      if busy?
        pbMessage(_INTL("You are already in a trade."))
        return
      end
      list = PEMK::Remotes.players.values
      if list.empty?
        pbMessage(_INTL("There are no other players on this map."))
        return
      end
      names  = list.map { |rp| rp.player_name || _INTL("Player {1}", rp.player_id) }
      choice = pbMessage(_INTL("Trade with which player?"), names + [_INTL("Cancel")], list.length)
      return if choice < 0 || choice >= list.length

      target = list[choice]
      tid = "#{[PEMK.self_id, target.player_id].min}:#{[PEMK.self_id, target.player_id].max}:#{rand(2**62)}"
      @session = { :trade_id => tid, :partner => target.player_id, :partner_name => names[choice],
                   :phase => :awaiting_accept, :since => now, :my_locked => false }
      relay(:trade_invite, :name => own_name)
      pbMessage(_INTL("Trade request sent to {1}...", names[choice]))
    end

    # --- inbound (from Dispatch, inside the pump — NO blocking UI here) ----------
    def on_message(msg)
      case msg[:type]
      when :trade_invite
        return unless msg[:to] == PEMK.self_id
        if busy? || @invite
          # already occupied -> auto-decline so the inviter is freed immediately
          # (rather than hanging on its :awaiting_accept watchdog).
          PEMK.send_message({ :type => :trade_decline, :from => PEMK.self_id, :to => msg[:from],
                              :trade_id => msg[:trade_id], :name => own_name })
          return
        end
        @invite = { :from => msg[:from], :name => msg[:name] || "?", :trade_id => msg[:trade_id] }
      when :trade_accept
        return unless mine?(msg) && @session[:phase] == :awaiting_accept
        @session[:phase] = :choosing
        @session[:since] = now
      when :trade_decline
        return unless mine?(msg)
        finish(_INTL("{1} declined the trade.", @session[:partner_name]))
      when :trade_offer
        return unless mine?(msg)
        return if @session[:their_uid]   # first offer only (no mid-flow changes)
        return unless msg[:uid].is_a?(Integer)
        @session[:their_uid]     = msg[:uid]
        @session[:their_species] = msg[:species]
        @session[:their_level]   = msg[:level]
        @session[:their_name]    = msg[:name] || "?"
        # If I already offered and was waiting, both offers are now known.
        @session[:phase] = :confirming if @session[:my_uid] && @session[:phase] == :waiting_offer
      when :trade_lock
        return unless mine?(msg)
        obj = msg[:_body] ? (Marshal.load(msg[:_body]) rescue nil) : nil
        obj = obj[0] if obj.is_a?(Array)
        # Cross-check the escrow object against the announced offer: same uid AND
        # species -> a scammer can't lock a different/fabricated mon than offered.
        unless obj.is_a?(Pokemon) && obj.pemk_uid == @session[:their_uid] && obj.species == @session[:their_species]
          PEMK.log("trade: escrow cross-check failed -> abort")
          relay(:trade_cancel)
          finish(_INTL("Trade error — the offer did not match. Cancelled."))
          return
        end
        @session[:their_obj] = obj
        maybe_commit
      when :trade_cancel
        return unless mine?(msg)
        finish(_INTL("{1} cancelled the trade.", @session[:partner_name]))
      end
    end

    # --- inbound server result (authoritative; NOT relayed) ---------------------
    def on_result(msg)
      return unless @session && msg[:trade_id] == @session[:trade_id]

      if msg[:ok]
        # The swap committed. Evict the mon we gave FIRST (frees a party slot), THEN
        # materialize the escrowed mon (now server-owned by us) so a full party
        # doesn't push the received mon into the PC box. Both by uid; then checkpoint.
        recv = Array(msg[:recv])
        gave = Array(msg[:gave])
        obj  = @session[:their_obj]
        gave.each { |uid| PEMK::Monsters.remove_by_uid(uid) }
        PEMK::Monsters.materialize(obj) if obj && recv.include?(obj.pemk_uid)
        name = @session[:partner_name]
        finish(_INTL("The trade with {1} is complete!", name))
        (PEMK::Sync.mark_mon rescue nil)
        (PEMK::Checkpoint.request(:trade) rescue nil)   # urgent -> both sides persist within ~1s
      else
        finish(_INTL("The trade could not be completed ({1}).", msg[:reason] || "error"))
      end
    end

    # --- UI: advance the state machine on a safe overworld frame ----------------
    def update_ui
      return if @in_ui
      return unless $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_menu &&
                    !$game_temp.message_window_showing && !(pbMapInterpreterRunning? rescue true)

      @in_ui = true
      begin
        if @notice
          m = @notice
          @notice = nil
          pbMessage(m)
        elsif @invite && !busy?
          handle_invite
        elsif @session
          advance
        end
      ensure
        @in_ui = false
      end
    end

    # --- helpers ----------------------------------------------------------------

    def handle_invite
      inv = @invite
      @invite = nil
      if pbConfirmMessage(_INTL("{1} wants to trade! Accept?", inv[:name]))
        @session = { :trade_id => inv[:trade_id], :partner => inv[:from],
                     :partner_name => inv[:name], :phase => :choosing, :since => now, :my_locked => false }
        relay(:trade_accept, :name => own_name)
      else
        PEMK.send_message({ :type => :trade_decline, :from => PEMK.self_id, :to => inv[:from],
                            :trade_id => inv[:trade_id], :name => own_name })
      end
    end

    def advance
      case @session[:phase]
      when :choosing
        pkmn = choose_offer_mon
        # The blocking picker pumps the network; the partner may have cancelled/
        # timed out (nil'ing @session) while it was open. Bail before touching it.
        return unless @session && @session[:phase] == :choosing

        if pkmn.nil?
          relay(:trade_cancel)
          finish_local(_INTL("Trade cancelled."))
        else
          @session[:my_uid]  = pkmn.pemk_uid
          @session[:my_pkmn] = pkmn
          relay(:trade_offer, :uid => pkmn.pemk_uid, :species => pkmn.species,
                              :level => pkmn.level, :name => pkmn.name)
          @session[:phase] = @session[:their_uid] ? :confirming : :waiting_offer
          @session[:since] = now
        end
      when :confirming
        mine = @session[:my_pkmn].name
        tid  = @session[:trade_id]
        ok = pbConfirmMessage(_INTL("Trade your {1} for {2}'s {3}?", mine, @session[:partner_name], @session[:their_name]))
        # Same race: a partner cancel/timeout during the confirm dialog nils @session.
        return unless @session && @session[:trade_id] == tid

        if ok
          body = Marshal.dump([@session[:my_pkmn]])   # the REAL object (server never loads it)
          PEMK.send_message({ :type => :trade_lock, :from => PEMK.self_id, :to => @session[:partner],
                              :trade_id => @session[:trade_id], :uid => @session[:my_uid] }, body)
          @session[:my_locked] = true
          @session[:phase] = :locked_waiting
          @session[:since] = now
          maybe_commit
        else
          relay(:trade_cancel)
          finish_local(_INTL("Trade cancelled."))
        end
      when :awaiting_accept, :waiting_offer, :locked_waiting
        # PRE-commit waits only: a local cancel here is safe (no swap has run).
        # :committing is deliberately EXCLUDED — once :trade_commit is sent the
        # swap is server-decided and irrevocable; we wait for the authoritative
        # :trade_result (a dead link is cleared by Sync.reset -> Trade.reset).
        if (now - @session[:since]) > TIMEOUT
          relay(:trade_cancel)
          finish_local(_INTL("The trade timed out."))
        end
      end
    end

    # I commit ONLY once I have locked AND hold the partner's validated object.
    def maybe_commit
      return unless @session && @session[:my_locked] && @session[:their_obj]
      return if @session[:phase] == :committing

      PEMK.send_message({ :type => :trade_commit, :trade_id => @session[:trade_id],
                          :partner => @session[:partner], :give => [@session[:my_uid]],
                          :recv => [@session[:their_uid]] })
      @session[:phase] = :committing
      @session[:since] = now
    end

    def choose_offer_mon
      party = $player.party
      loop do
        names = party.map { |p| p.egg? ? _INTL("{1} (Egg)", p.name) : _INTL("{1} Lv. {2}", p.name, p.level) }
        choice = pbMessage(_INTL("Offer which Pokémon?"), names + [_INTL("Cancel")], party.length)
        return nil if choice < 0 || choice >= party.length

        pkmn   = party[choice]
        reason = untradeable_reason(pkmn)
        if reason
          pbMessage(reason)
          next
        end
        return pkmn
      end
    end

    # Untradeable gate (party source): eggs, fused mons, a not-yet-registered mon,
    # and your LAST able Pokémon (soft-lock guard).
    def untradeable_reason(pkmn)
      return _INTL("You can't trade an Egg.") if pkmn.egg?
      return _INTL("You can't trade a fused Pokémon.") if pkmn.fused
      return _INTL("This Pokémon isn't registered on the server yet — try again in a moment.") if pkmn.pemk_uid.nil?
      return _INTL("You can't trade your last able Pokémon.") if pkmn.able? && $player.able_pokemon_count <= 1

      nil
    end

    # Send a peer frame over the ADDRESSED relay (to the current partner).
    def relay(type, extra = {})
      return unless @session

      PEMK.send_message({ :type => type, :from => PEMK.self_id, :to => @session[:partner],
                          :trade_id => @session[:trade_id] }.merge(extra))
    end

    # Frame belongs to my active session (right partner + trade_id).
    def mine?(msg)
      @session && msg[:to] == PEMK.self_id && msg[:trade_id] == @session[:trade_id] &&
        msg[:from] == @session[:partner]
    end

    # End with a player message (used when the OTHER side ended it or on success).
    def finish(message)
      @session = nil
      @notice  = message
    end

    # End quietly-ish for a LOCAL action (already messaged, or a plain cancel).
    def finish_local(message)
      @session = nil
      @notice  = message
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end

# Pause-menu entry + the safe-frame UI driver (mirrors the battle-challenge wiring).
MenuHandlers.add(:pause_menu, :mmo_trade, {
  "name"      => _INTL("Trade Player"),
  "order"     => 56,
  "condition" => proc { next PEMK.enabled? && PEMK.client && PEMK.client.connected? },
  "effect"    => proc { |menu|
    menu.pbHideMenu
    PEMK::Trade.pbTradeFromMenu
    menu.pbEndScene
    next true
  }
})

EventHandlers.add(:on_frame_update, :pemk_trade_ui,
  proc { PEMK::Trade.update_ui })
