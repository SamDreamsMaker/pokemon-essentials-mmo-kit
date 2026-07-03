#===============================================================================
# PEMK :: NetStatus  (connection honesty + mid-session reconnection)
#-------------------------------------------------------------------------------
# Before this file existed, a mid-session socket drop was SILENT and permanent:
# no reconnection path existed (ensure_started is one-shot), logged_in? stayed
# sticky, "Saved!" lied (the push went nowhere), and the entire rest of the
# session was discarded at the next login. This module:
#   - tells the player the truth (queued English notices shown at a safe frame,
#     via :on_frame_update like the challenge prompts — NEVER from the pump),
#   - reconnects on a backoff (transport restart + session-token re-auth) and
#     re-seeds the server: T1 channels are absolute values so client-wins re-seed
#     is trivial; the blob re-pushes force:true.
# Mid-session re-auth deliberately does NOT hydrate pending_state/econ/inv —
# restoring server state onto a LIVE player would rewind them.
#===============================================================================
module PEMK
  module NetStatus
    RECONNECT_BASE = 5.0
    RECONNECT_MAX  = 60.0

    @notices      = []      # queued player messages (English), shown at safe frames
    @shown        = {}      # dedup keys
    @reconnect_at = nil     # monotonic time of the next attempt (nil = not scheduled)
    @backoff      = RECONNECT_BASE
    @terminal     = false   # session token rejected -> reconnection can never succeed

    module_function

    # Queue a player-facing notice (deduped by key until the key is reset).
    def notify(key, msg)
      return if key && @shown[key]

      @shown[key] = true if key
      @notices << msg
    end

    def reset_key(key)
      @shown.delete(key)
    end

    # Dispatch saw DISCONNECTED. Only meaningful once logged in (boot-time
    # offline is handled by Auth.login_blocking).
    def on_disconnect
      return if @terminal
      return unless PEMK::Auth.logged_in?
      return if @reconnect_at   # already scheduled

      PEMK.log("net: connection lost -> reconnect scheduled (#{@backoff.to_i}s)")
      notify(:lost, _INTL("Connection to the server was lost. Your progress is NO LONGER being saved online. Reconnecting..."))
      @reconnect_at = mono + @backoff
    end

    # Reconnect FSM — from Pump.tick (socket work only, no UI here). The FSM is
    # disarmed ONLY by a successful re-auth in attempt_reconnect — a transport
    # that merely CONNECTED is unauthenticated (the server drops its frames and
    # kills it), so "connected?" must never clear the schedule.
    def tick
      return if @terminal

      if @reconnect_at.nil?
        # Self-arm belt: a drop first noticed by a WRITE (no FIN/RST) may never
        # surface as a DISCONNECTED message — any dead transport while logged in
        # arms the FSM here.
        c = PEMK.client
        on_disconnect if PEMK::Auth.logged_in? && (c.nil? || !c.connected?)
        return
      end
      return if mono < @reconnect_at
      return if $game_temp&.in_battle   # a connect/auth freeze mid-battle would be worse

      attempt_reconnect
    end

    # Player notices — from :on_frame_update (a real safe frame, like Challenge).
    def update_ui
      return if @notices.empty?
      return unless $player && $scene.is_a?(Scene_Map) && $game_temp &&
                    !$game_temp.in_battle && !$game_temp.in_menu &&
                    !$game_temp.message_window_showing && !(pbMapInterpreterRunning? rescue true)

      msg = @notices.shift
      (pbMessage(msg) rescue nil)
    end

    def attempt_reconnect
      PEMK.log("net: reconnect attempt (backoff #{@backoff.to_i}s)")
      PEMK.shutdown
      PEMK.ensure_started
      c = PEMK.client
      result = (c && c.connected?) ? PEMK::Auth.relogin(c) : :net
      case result
      when :ok
        PEMK.log("net: reconnected + re-authenticated")
        @reconnect_at = nil
        @backoff = RECONNECT_BASE
        reset_key(:lost)
        reset_key(:save_not_synced)
        notify(nil, _INTL("Connection restored. Your progress is saving online again."))
        PEMK::Auth.reseed_after_reconnect
      when :auth_err
        # The token is unusable (expired session / wrong account): retrying can
        # never succeed. Stop for good and tell the player plainly.
        @terminal     = true
        @reconnect_at = nil
        PEMK.shutdown
        PEMK.log("net: relogin rejected -> reconnection stopped (restart required)")
        notify(nil, _INTL("Your online session has expired. Please restart the game to log in again."))
      else # :net — transport/timeout; never leave an unauthenticated socket alive
        PEMK.shutdown
        @backoff      = [@backoff * 2, RECONNECT_MAX].min
        @reconnect_at = mono + @backoff
      end
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end

EventHandlers.add(:on_frame_update, :pemk_netstatus_ui,
  proc { PEMK::NetStatus.update_ui })
