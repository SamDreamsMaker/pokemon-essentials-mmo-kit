#===============================================================================
# PEMK :: DebugLock - debug mode stays off where the server says
#-------------------------------------------------------------------------------
# Essentials' debug mode ($DEBUG) walks through walls, decides trainer battles, uses
# field moves with no badge and opens the debug menus - turned on by a `debug` launch or
# an event's `$DEBUG = true` (the stock demo's house helper offers it to anyone), with
# no modified client. A server that denies it (PEMK_CLIENT_DEBUG: deny, or autopilot)
# says so at login and auth: from then on, for the rest of the process, every write of
# $DEBUG (or $-d) is undone as it happens - trace_var, so no event command after the
# write sees it on - and each frame checks again (005_Hooks). A logout, a lost link or a
# server that says nothing never lift it. Under deny the autopilot only reads.
# A modified client ignores all this: the server's own checks stay the truth.
#===============================================================================
module PEMK
  module DebugLock
    @level   = nil     # nil (not locked) | :autopilot | :deny
    @noticed = false   # the player was told once

    module_function

    def locked?
      !@level.nil?
    end

    # The autopilot may change the game (else it only reads): not once a server denied it.
    def autopilot_allowed?
      @level != :deny
    end

    # login_ok / auth_ok's :client_debug. "deny" or "autopilot" lock it; nothing unlocks.
    def adopt(value)
      level = { "deny" => :deny, "autopilot" => :autopilot }[value.to_s]
      return unless level

      first = @level.nil?
      denied = level == :deny && @level != :deny
      @level = level if first || level == :deny   # deny wins: the autopilot stays read-only
      (PEMK::Autopilot.disarm if PEMK::Autopilot.active?) if denied && defined?(PEMK::Autopilot)
      return unless first

      trace_var(:$DEBUG) { |on| turn_off if on }
      trace_var(:$-d) { |on| turn_off if on }
      turn_off
    rescue StandardError => e
      PEMK.log("debug: lock error #{e.class}: #{e.message}")
    end

    # Each frame (and each write): debug mode back off, the player told the first time.
    def tick
      turn_off if @level && ($DEBUG || $-d)
    end

    def turn_off
      return unless $DEBUG || $-d

      $DEBUG = false
      $-d = false
      return if @noticed

      @noticed = true
      map = ($game_map ? $game_map.map_id : nil) rescue nil
      PEMK.log("debug: turned off#{map ? " on map #{map}" : ''} - this server keeps debug mode off")
      # the player is told on a server that denies it (the autotest's level says nothing:
      # a message box would wait for a key after each relaunch)
      return unless @level == :deny

      (PEMK::NetStatus.notify(:debug_off, _INTL("Debug mode is off on this server.")) rescue nil)
    end
  end
end
