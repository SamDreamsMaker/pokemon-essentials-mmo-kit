#===============================================================================
# PokeMMO :: Hooks
#-------------------------------------------------------------------------------
# Wires the SDK into the engine WITHOUT editing the core — only EventHandlers.add
# and one guarded alias of the global pbUpdateSceneMap.
#
#   Pump.tick : once per frame, drives the relay (host), drains the client, and
#   advances remote-player interpolation. Called from :on_frame_update (normal
#   overworld) AND the pbUpdateSceneMap alias (blocking loops: messages/menus),
#   throttled to once per Graphics.frame_count so it never double-steps.
#===============================================================================
module PokeMMO
  module Pump
    @in_pump    = false
    @last_frame = nil

    def self.tick
      return if @in_pump
      fc = (Graphics.frame_count rescue -1)
      return if fc != -1 && fc == @last_frame   # already pumped this frame
      @in_pump = true
      @last_frame = fc
      begin
        PokeMMO.ensure_started
        r = PokeMMO.relay
        r.pump if r
        c = PokeMMO.client
        c.poll.each { |m| PokeMMO::Dispatch.handle(m) } if c && c.connected?
        PokeMMO::Remotes.prune          # drop timed-out (disconnected) players
        PokeMMO::Remotes.update_all
        PokeMMO::Presence.heartbeat
      rescue => e
        PokeMMO.log("Pump error: #{e.class}: #{e.message}")
      ensure
        @in_pump = false
      end
    end
  end
end

# --- Per-frame pump in the overworld (Scene_Map#updateSpritesets) -------------
# NB: EventHandlers.add(event, key, proc) takes the handler as its 3rd argument
# (a proc), not a block.
EventHandlers.add(:on_frame_update, :pokemmo_pump,
  proc { PokeMMO::Pump.tick })

# --- Emit the local player's presence on step / turn --------------------------
EventHandlers.add(:on_player_step_taken, :pokemmo_emit_step,
  proc { PokeMMO::Presence.emit(:pos) })

EventHandlers.add(:on_player_change_direction, :pokemmo_emit_turn,
  proc { PokeMMO::Presence.emit(:dir) })

# --- Recreate remote sprites whenever a spriteset is (re)built ----------------
EventHandlers.add(:on_new_spriteset_map, :pokemmo_remote_sprites,
  proc { |spriteset, viewport| PokeMMO::Remotes.on_new_spriteset(spriteset, viewport) })

# --- Clear remotes on zone change, then re-announce our new position ----------
# NB: don't emit here directly — the player's tile isn't final yet at :on_enter_map,
# which made others briefly see us at the old spot. announce_soon defers to the
# next idle heartbeat, which reads the settled position.
EventHandlers.add(:on_enter_map, :pokemmo_zone_reset,
  proc { |_old_map_id| PokeMMO::Remotes.clear_all; PokeMMO::Presence.announce_soon })

# --- Battle challenge (Phase 4a): pause-menu option + the prompt driver --------
MenuHandlers.add(:pause_menu, :mmo_challenge, {
  "name"      => _INTL("Battle Player"),
  "order"     => 55,
  "condition" => proc { next PokeMMO.enabled? && PokeMMO.client && PokeMMO.client.connected? },
  "effect"    => proc { |menu|
    menu.pbHideMenu
    PokeMMO::Challenge.pbChallengeFromMenu
    menu.pbEndScene
    next true
  }
})

# Shows incoming challenge prompts / replies on a safe frame (not in the pump).
EventHandlers.add(:on_frame_update, :pokemmo_challenge_ui,
  proc { PokeMMO::Challenge.update_ui })

# --- Keep the network alive during blocking overworld loops -------------------
# pbUpdateSceneMap is the single global function every message/menu/wait loop
# calls; aliasing it (guarded, idempotent) pumps there too. Pump.tick throttles
# itself per frame, so being called from both paths is safe.
class Object
  unless private_method_defined?(:pokemmo_orig_pbUpdateSceneMap) ||
         method_defined?(:pokemmo_orig_pbUpdateSceneMap)
    alias_method :pokemmo_orig_pbUpdateSceneMap, :pbUpdateSceneMap
    def pbUpdateSceneMap
      pokemmo_orig_pbUpdateSceneMap
      PokeMMO::Pump.tick
    end
  end
end

# Load marker (proves every file parsed and top-level wiring ran to completion).
PokeMMO.log("plugin loaded OK (role=#{PokeMMO::Config::ROLE}, port=#{PokeMMO::Config::PORT})")
