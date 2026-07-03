#===============================================================================
# PEMK :: Hooks
#-------------------------------------------------------------------------------
# Wires the SDK into the engine WITHOUT editing the core — only EventHandlers.add
# and one guarded alias of the global pbUpdateSceneMap.
#
#   Pump.tick : once per frame, drives the relay (host), drains the client, and
#   advances remote-player interpolation. Called from :on_frame_update (normal
#   overworld) AND the pbUpdateSceneMap alias (blocking loops: messages/menus),
#   throttled to once per Graphics.frame_count so it never double-steps.
#===============================================================================
module PEMK
  module Pump
    @in_pump    = false
    @last_frame = nil

    def self.tick
      return if @in_pump
      return unless $player   # only once a game is loaded (skip title / load screen)
      fc = (Graphics.frame_count rescue -1)
      return if fc != -1 && fc == @last_frame   # already pumped this frame
      @in_pump = true
      @last_frame = fc
      begin
        PEMK.ensure_started
        r = PEMK.relay
        r.pump if r
        c = PEMK.client
        # Poll even when disconnected: a write-detected drop surfaces as one
        # DISCONNECTED message from poll (arming the reconnect FSM).
        c.poll.each { |m| PEMK::Dispatch.handle(m) } if c
        PEMK::Remotes.prune          # drop timed-out (disconnected) players
        PEMK::Remotes.update_all
        PEMK::Presence.heartbeat
        PEMK::Sync.tick              # coalesced state-delta flush (debounce/staleness)
        PEMK::Checkpoint.tick        # gated auto-persistence executor (O(1) when idle)
        PEMK::NetStatus.tick         # mid-session reconnect FSM (no UI here)
      rescue => e
        PEMK.log("Pump error: #{e.class}: #{e.message}")
      ensure
        @in_pump = false
      end
    end
  end
end

# --- The single per-frame pump: alias Graphics.update -------------------------
# Graphics.update is called exactly once per frame in EVERY scene — the overworld,
# battles, AND every full-screen menu (Bag, Pokédex, Party, Storage, Pokégear…).
# Driving the pump from here, and NOWHERE else, keeps presence/networking alive
# everywhere (including inside big menus, which have their own update loops and
# never call pbUpdateSceneMap), with exactly one pump per frame (no burst).
# Pump.tick no-ops until a game is loaded ($player), so the title/load screen is
# untouched; login runs its own manual pump.
module Graphics
  class << self
    unless method_defined?(:pemk_orig_update)
      alias_method :pemk_orig_update, :update
      def update(*args)
        pemk_orig_update(*args)   # mkxp-z may raise SystemExit HERE on window close
        PEMK::Pump.tick
      rescue SystemExit
        # THE reliable exit backstop: the terminate exception unwinds through here
        # while the socket and game state are still intact, unlike at_exit (which
        # this build does not run). Take a last-chance save, then let the exit go.
        (PEMK::Checkpoint.on_terminate rescue nil)
        raise
      end
    end
  end
end

# mkxp-z checks the async shutdown flag in BOTH Graphics.update AND Input.update
# (Scene_Map#main calls them back-to-back each frame). A window closed while idle
# in the overworld is USUALLY observed first by Input.update — so the terminate
# SystemExit raises there, bypassing the Graphics.update rescue above. Mirror the
# same backstop here (on_terminate is re-entrancy-guarded + idempotent).
module Input
  class << self
    unless method_defined?(:pemk_orig_input_update)
      alias_method :pemk_orig_input_update, :update
      def update(*args)
        pemk_orig_input_update(*args)
      rescue SystemExit
        (PEMK::Checkpoint.on_terminate rescue nil)
        raise
      end
    end
  end
end

# --- Emit the local player's presence on step / turn --------------------------
EventHandlers.add(:on_player_step_taken, :pokemmo_emit_step,
  proc { PEMK::Presence.emit(:pos) })

EventHandlers.add(:on_player_change_direction, :pokemmo_emit_turn,
  proc { PEMK::Presence.emit(:dir) })

# --- Recreate remote sprites whenever a spriteset is (re)built ----------------
EventHandlers.add(:on_new_spriteset_map, :pokemmo_remote_sprites,
  proc { |spriteset, viewport| PEMK::Remotes.on_new_spriteset(spriteset, viewport) })

# --- Clear remotes on zone change, then re-announce our new position ----------
# NB: don't emit here directly — the player's tile isn't final yet at :on_enter_map,
# which made others briefly see us at the old spot. announce_soon defers to the
# next idle heartbeat, which reads the settled position.
EventHandlers.add(:on_enter_map, :pokemmo_zone_reset,
  proc { |_old_map_id|
    PEMK::Remotes.clear_all
    PEMK::Presence.announce_soon
    PEMK::Sync.flush_event(:map)
    PEMK::Checkpoint.request(:map)   # flag-only; executes at the first safe frame
  })

# --- Battle challenge (Phase 4a): pause-menu option + the prompt driver --------
MenuHandlers.add(:pause_menu, :mmo_challenge, {
  "name"      => _INTL("Battle Player"),
  "order"     => 55,
  "condition" => proc { next PEMK.enabled? && PEMK.client && PEMK.client.connected? },
  "effect"    => proc { |menu|
    menu.pbHideMenu
    PEMK::Challenge.pbChallengeFromMenu
    menu.pbEndScene
    next true
  }
})

# Shows incoming challenge prompts / replies on a safe frame (not in the pump).
EventHandlers.add(:on_frame_update, :pokemmo_challenge_ui,
  proc { PEMK::Challenge.update_ui })

# Start an accepted PvP battle from a CLEAN stack point: the top of
# Scene_Map#update, before updateSpritesets runs. Launching from :on_frame_update
# (fired from *inside* updateSpritesets) would nest the battle's own
# updateSpritesets calls and crash overworld sprites. This is where the engine
# itself starts battles (pbMapInterpreter.update, also before updateSpritesets).
class Scene_Map
  unless method_defined?(:pokemmo_orig_scene_update)
    alias_method :pokemmo_orig_scene_update, :update
    def update
      PEMK::BattleSetup.run_pending_launch
      pokemmo_orig_scene_update
    end
  end
end

# Load marker (proves every file parsed and top-level wiring ran to completion).
PEMK.log("plugin loaded OK (role=#{PEMK::Config::ROLE}, port=#{PEMK::Config::PORT})")
