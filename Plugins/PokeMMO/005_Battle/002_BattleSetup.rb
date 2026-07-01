#===============================================================================
# PokeMMO :: BattleSetup  (Phase 4b.1 — team exchange)
#-------------------------------------------------------------------------------
# Once a challenge is accepted, both players send each other their party (the
# Pokémon objects ride along in a Marshal'd message, exactly as RecordedBattle
# already serialises parties). Each side stores the opponent's team; launching
# the actual battle from these teams is Phase 4b.2.
#
# NOTE: teams currently go through the broadcast relay (filtered by :to), so a
# team is visible to every connected client — fine for a trusted host+friends
# setup, to be tightened (server-routed, confidential) alongside the filtered
# replay in Phase 4d.
#===============================================================================
module PokeMMO
  module BattleSetup
    @opponents = {}   # account_id => { :name, :party }  (received opponent teams)
    @queued    = nil  # a message to show on the next safe frame

    def self.own_name
      ($player && $player.name) ? $player.name : "?"
    end

    # Send our party to +to_id+ (called by both sides when a battle is agreed).
    def self.send_team(to_id)
      return unless PokeMMO.client && PokeMMO.client.connected? && $player && $player.party
      PokeMMO.send_message({ :type => :battle_team, :from => PokeMMO.self_id,
                             :name => own_name, :to => to_id, :party => $player.party })
      PokeMMO.log("battle: sent my team (#{$player.party.length} Pokemon) to #{to_id}")
    end

    # Routed from Dispatch (inside the pump — no blocking UI here).
    def self.on_team(msg)
      return unless msg[:to] == PokeMMO.self_id
      party = msg[:party]
      return unless party.is_a?(Array) && !party.empty?
      @opponents[msg[:from]] = { :name => msg[:name] || "?", :party => party }
      PokeMMO.log("battle: received team from #{msg[:from]} (#{party.length} Pokemon)")
      names = party.map { |pk| (pk.name rescue nil) || "?" }.join(", ")
      @queued = _INTL("{1}'s team is ready: {2}\n(The battle itself starts in Phase 4b.2.)",
                      msg[:name] || "?", names)
    end

    def self.opponent(account_id)
      @opponents[account_id]
    end

    # Shows the queued confirmation on a safe frame (from :on_frame_update).
    def self.update_ui
      return unless @queued
      return unless $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_menu
      m = @queued
      @queued = nil
      pbMessage(m)
    end
  end
end
