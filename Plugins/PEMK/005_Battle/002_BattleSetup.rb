#===============================================================================
# PEMK :: BattleSetup  (Phase 4b — team exchange + battle launch)
#-------------------------------------------------------------------------------
# Once a challenge is accepted, both players send each other their party. The
# Pokémon objects ride as an OPAQUE Marshal body (kept as Marshal so it stays
# correct across upstream Pokémon-class changes); the primitive envelope carries
# only routing/name/trainer-type. When THIS side has received the opponent's team,
# it starts the battle (BattleLauncher) on a safe frame.
#
# The relay routes the team to the addressed recipient ALONE and never decodes the
# body, so a party is confidential and the host never Marshal.loads it. Only the
# recipient reconstructs the party (a bounded Pokémon-graph load — the accepted
# residual of the wire-hardening work).
#===============================================================================
module PEMK
  module BattleSetup
    @opponents      = {}   # account_id => { :name, :party }  (received opponent teams)
    @pending_launch = nil  # opponent hash to start a battle against, on the next safe frame
    @launching      = false # re-entrancy guard (a battle is blocking)

    def self.own_name
      ($player && $player.name) ? $player.name : "?"
    end

    # Send our party to +to_id+ (called by both sides when a battle is agreed).
    def self.send_team(to_id)
      return unless PEMK.client && PEMK.client.connected? && $player && $player.party
      ttype = ($player.trainer_type rescue nil)
      # The party (Pokémon objects) rides as an opaque body; the relay never loads
      # it and only +to_id+ receives it.
      body = Marshal.dump($player.party)
      PEMK.send_message({ :type => :battle_team, :from => PEMK.self_id, :name => own_name,
                             :to => to_id, :trainer_type => ttype }, body)
      PEMK.log("battle: sent my team (#{$player.party.length} Pokemon) to #{to_id}")
    end

    # Routed from Dispatch (inside the pump — no blocking UI/battle here).
    def self.on_team(msg)
      return unless msg[:to] == PEMK.self_id
      # Reconstruct the opponent party from the opaque body (our own decode, on the
      # addressed frame). Legacy :party kept as a fallback during migration.
      party = (msg[:_body] ? (Marshal.load(msg[:_body]) rescue nil) : msg[:party])
      return unless party.is_a?(Array) && !party.empty?
      remote = { :name => msg[:name] || "?", :party => party, :id => msg[:from],
                 :trainer_type => msg[:trainer_type] }
      @opponents[msg[:from]] = remote
      PEMK.log("battle: received team from #{msg[:from]} (#{party.length} Pokemon)")
      @pending_launch = remote   # both teams are known on this side -> start the battle
    end

    def self.opponent(account_id)
      @opponents[account_id]
    end

    # Starts the pending battle from a CLEAN stack point — the top of
    # Scene_Map#update, before updateSpritesets (see Hooks). Launching from
    # :on_frame_update instead nests the battle inside updateSpritesets, so
    # pbBattleAnimation re-enters updateSpritesets and crashes overworld sprites
    # (e.g. berry plants). This mirrors how the engine starts normal battles
    # (from pbMapInterpreter.update, also before updateSpritesets).
    def self.run_pending_launch
      return if @launching
      return unless @pending_launch
      return unless $scene.is_a?(Scene_Map) && $player
      return if $game_temp && ($game_temp.in_menu || $game_temp.in_battle)
      return if $game_player && $game_player.moving?
      remote = @pending_launch
      @pending_launch = nil
      @launching = true
      begin
        BattleLauncher.start_pvp(remote)
      ensure
        @launching = false
      end
    end
  end
end
