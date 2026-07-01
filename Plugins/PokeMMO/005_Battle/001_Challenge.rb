#===============================================================================
# PokeMMO :: Challenge  (Phase 4a — battle challenge / accept handshake)
#-------------------------------------------------------------------------------
# The networking + UI channel that lets one player challenge another to a battle.
# 4a stops at "accepted" — actually starting the battle is Phase 4b.
#
# Messages are relayed (broadcast) with a :to field; each client acts only on the
# ones addressed to its own account id. Prompts are shown from :on_frame_update
# (never from inside the network pump), so blocking message loops are safe.
#===============================================================================
module PokeMMO
  module Challenge
    @incoming        = nil   # {from:, name:} — a challenge to prompt the player about
    @outgoing        = nil   # account id we challenged (awaiting a reply)
    @pending_message = nil   # a reply to show ("X accepted/declined")
    @in_ui           = false # re-entrancy guard for the blocking prompts

    def self.own_name
      $player ? $player.name : "?"
    end

    # --- Sending: called from the pause-menu option ---------------------------
    def self.pbChallengeFromMenu
      unless PokeMMO.client && PokeMMO.client.connected?
        pbMessage(_INTL("You are not connected to a server."))
        return
      end
      list = PokeMMO::Remotes.players.values
      if list.empty?
        pbMessage(_INTL("There are no other players on this map."))
        return
      end
      names  = list.map { |rp| rp.player_name || _INTL("Player {1}", rp.player_id) }
      choice = pbMessage(_INTL("Challenge which player?"), names + [_INTL("Cancel")], list.length)
      return if choice < 0 || choice >= list.length
      target = list[choice]
      @outgoing = target.player_id
      PokeMMO.send_message({ :type => :challenge, :from => PokeMMO.self_id,
                             :name => own_name, :to => target.player_id })
      pbMessage(_INTL("Battle request sent to {1}...", names[choice]))
    end

    # --- Receiving: routed from Dispatch (runs inside the pump — no UI here) ---
    def self.on_message(msg)
      case msg[:type]
      when :challenge
        return unless msg[:to] == PokeMMO.self_id
        @incoming = { :from => msg[:from], :name => msg[:name] || "?" }
      when :challenge_accept
        return unless msg[:to] == PokeMMO.self_id
        @outgoing = nil
        @pending_message = _INTL("{1} accepted your battle request!", msg[:name] || "?")
      when :challenge_decline
        return unless msg[:to] == PokeMMO.self_id
        @outgoing = nil
        @pending_message = _INTL("{1} declined your battle request.", msg[:name] || "?")
      end
    end

    # --- UI: show any pending prompt on a safe frame (from :on_frame_update) ---
    def self.update_ui
      return if @in_ui
      return unless $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_menu
      return unless @pending_message || @incoming
      @in_ui = true
      begin
        if @pending_message
          m = @pending_message
          @pending_message = nil
          pbMessage(m)   # TODO 4b: if this was an accept, start the battle here
        elsif @incoming
          inc = @incoming
          @incoming = nil
          if pbConfirmMessage(_INTL("{1} wants to battle! Accept?", inc[:name]))
            PokeMMO.send_message({ :type => :challenge_accept, :from => PokeMMO.self_id,
                                   :name => own_name, :to => inc[:from] })
            pbMessage(_INTL("Battle accepted! (The battle itself is coming in Phase 4b.)"))
          else
            PokeMMO.send_message({ :type => :challenge_decline, :from => PokeMMO.self_id,
                                   :name => own_name, :to => inc[:from] })
          end
        end
      ensure
        @in_ui = false
      end
    end
  end
end
