# frozen_string_literal: true

module PEMK
  # POSITION audit (Milestone 4, Layer B). Reuses the presence stream the server
  # ALREADY receives (handle_presence) — no new client message. On every
  # :pos/:step/:dir/:spawn frame it compares the player's tile against the read-only
  # world model and LOGS a violation. Per-connection previous tile lives in
  # conn_data[:last_pos], scoped to the connection and cleared on disconnect.
  #
  # ENFORCEMENT MODE (config PEMK_POS_ENFORCE), staged safety-first:
  #   :off    (default) detection only — log the verdict, do nothing else.
  #   :shadow ALSO log "WOULD-CORRECT <bad> -> <last-good>" for enforceable verdicts,
  #           but still correct NOTHING. This lets us watch what enforcement would do
  #           (and catch remaining false positives) before it can ever yank a player.
  #   :on     (future slice) actually emit a snap-back correction.
  # Only high-confidence verdicts are enforceable (:noclip, :illegal_warp); :teleport
  # stays detection-only because ledge/speed FPs are likelier there.
  #
  # Modelled on Audit: verdict symbols, trunc() bounding, rescue so it never kills the
  # reactor thread, identity = server-trusted account_id.
  #
  # Verdicts: :match (silent), :unchecked (no world / no data / genesis — silent),
  # :bad (malformed — silent), :noclip (stepped onto a fully-blocked tile),
  # :teleport (same-map jump > 1 tile), :illegal_warp (cross-map move that matches no
  # warp / spawn / connection).
  class PositionAudit
    ENFORCEABLE = %i[noclip illegal_warp].freeze # verdicts eligible for correction
    # The first frame after a warp can come a step past the arrival tile: a player
    # holding the arrow through a door, or a move route the arrival event starts (the
    # Pokemon Lab's). Only the arrival gets this slack; a wall next to it is still a wall.
    ARRIVAL_REACH = 1
    # The pace of a player's own steps, over a window of single-tile moves on one map: the
    # bike does 10 tiles a second (0.1 s a tile; running 8, walking 4). Frames arrive in
    # bursts (one read, one tick), so the window is long and the bar above the bike; a
    # cutscene's move route at speed 6 (20 tiles/s) over that many tiles is said too.
    # Detection only: said once per PACE_SAID, nothing corrected, nothing flagged.
    PACE_STEPS = 24
    PACE_MAX   = 15.0
    PACE_SAID  = 30.0

    def initialize(world, logger: nil, mode: :off, clock: nil)
      @world = world
      @log   = logger || ->(_m) {}
      @mode  = mode
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def check(account_id, env, conn_data)
      map = env[:map]; x = env[:x]; y = env[:y]
      return :bad unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      prev = conn_data[:last_pos]
      if @world.empty?
        conn_data[:last_pos] = [map, x, y]
        return :unchecked
      end

      verdict = classify(env, map, x, y, prev)
      if silent?(verdict)
        note_pace(account_id, conn_data, prev, map, x, y)
        conn_data[:last_pos] = [map, x, y]   # advance for the next frame
        return verdict
      end

      conn_data.delete(:pace)   # a violation: the window starts anew
      log_violation(account_id, env, map, x, y, prev, verdict)
      enforceable = prev && ENFORCEABLE.include?(verdict)

      if @mode == :on && enforceable
        # SNAP-BACK: do NOT advance last_pos to the bad tile — keep the last-good one,
        # so repeated bad frames all correct to the SAME tile (converge, never drift).
        # Signal server.rb (which holds the conn) to send the :pos_correct frame.
        conn_data[:correct_to] = prev
        log_enforce(account_id, map, x, y, prev, "SNAP-BACK")
      else
        conn_data[:last_pos] = [map, x, y]   # advance (off / shadow / non-enforceable)
        log_enforce(account_id, map, x, y, prev, "WOULD-CORRECT") if @mode == :shadow && enforceable
      end
      verdict
    rescue StandardError => e
      @log.call("posaudit: check error #{e.class}: #{e.message}")
      :bad
    end

    private

    def silent?(verdict)
      verdict == :match || verdict == :unchecked
    end

    # A single-tile step on the same map adds its time to the window; a repeat or a turn
    # adds nothing; a hop, a warp pad, a map change or the session's first frame starts a
    # new window. A full window faster than PACE_MAX is said - a modified client moving one
    # legal tile at a time, too fast - at most once per PACE_SAID.
    def note_pace(account_id, conn_data, prev, map, x, y)
      return conn_data.delete(:pace) unless prev && prev[0] == map

      px, py = prev[1], prev[2]
      return if x == px && y == py
      return conn_data.delete(:pace) if [(x - px).abs, (y - py).abs].max != 1

      times = (conn_data[:pace] ||= [])
      times << @clock.call
      times.shift while times.size > PACE_STEPS
      return if times.size < PACE_STEPS

      span = times.last - times.first
      pace = span.positive? ? (PACE_STEPS - 1) / span : Float::INFINITY
      return if pace <= PACE_MAX

      said = conn_data[:pace_said]
      return if said && times.last - said < PACE_SAID

      conn_data[:pace_said] = times.last
      @log.call(format("posaudit: account %s paces %.1f tiles/s over %d steps (the bike does 10)", account_id, pace, PACE_STEPS))
    end

    def classify(env, map, x, y, prev)
      # First frame for this connection (fresh socket, login/reconnect): no previous
      # tile to judge a step against, so trust it.
      return :unchecked if prev.nil?

      pmap, px, py = prev
      if pmap == map
        # A stationary frame (heartbeat re-announce / turn-in-place / a login-seeded
        # re-emit of the same tile) is not a MOVE, so it can't be a no-clip. This also
        # stops a login on a tile the export mis-marks as blocked (bridge/event) from
        # snap-back looping, and stops heartbeat no-clip spam while standing still.
        return :match if x == px && y == py

        # A known legal destination (a same-map warp pad / spin tile, or a spawn /
        # heal tile) is legal even if the passability export mis-marks it — check the
        # whitelist BEFORE noclip, mirroring the cross-map legal_transfer? ordering.
        return :match if @world.warp_dest?(map, map, x, y) || @world.spawn_tile?(map, x, y)

        # A door or stairs event sits on a tile the export marks as a wall: stepping
        # onto it is how its warp is taken. (A jump onto it is still a teleport.)
        return :noclip if noclip?(map, x, y, env) && !@world.warp_src?(map, x, y)

        # Chebyshev distance: an orthogonal OR diagonal single step is legal; a jump
        # of 2+ tiles between consecutive per-step frames is a teleport/speedhack —
        # UNLESS it is a LEDGE hop (a straight 2-tile jump over a ledge tile), or the
        # step after landing from a same-map warp (stairs) or a respawn.
        if [(x - px).abs, (y - py).abs].max > 1
          return :match if ledge_hop?(map, px, py, x, y)
          return :match if arrival?(map, map, x, y)

          return :teleport
        end

        :match
      else
        legal_transfer?(prev, map, x, y) ? :match : :illegal_warp
      end
    end

    # A ledge hop is a STRAIGHT 2-tile jump whose midpoint tile is a ledge (the
    # hop-over tile). Direction isn't enforced yet (a later refinement) — matching
    # the midpoint is enough to clear the common ledge false positive.
    def ledge_hop?(map, px, py, x, y)
      dx = x - px
      dy = y - py
      return false unless (dx.abs == 2 && dy.zero?) || (dy.abs == 2 && dx.zero?)

      @world.ledge?(map, px + dx / 2, py + dy / 2)
    end

    def noclip?(map, x, y, env)
      return false unless @world.walkable?(map, x, y) == false   # nil (no grid) is NEVER a violation

      !(env[:mode] == :surf && swims?(map, x, y))
    end

    # The passability grid counts water as walls: a surfer crosses only the water ones.
    # An export from before the water marks cannot tell them apart, so a surfer is
    # trusted there, as it always was. A diver walks the map below like the ground.
    def swims?(map, x, y)
      return true unless @world.water_marks?

      @world.water?(map, x, y) != false
    end

    def legal_transfer?(prev, map, x, y)
      pmap = prev[0]
      arrival?(pmap, map, x, y) ||            # a known warp from the old map, or a respawn
        @world.connected?(pmap, map) ||       # coarse edge-connection between the two maps
        dive?(prev, map, x, y)                # down from deep water, or back up onto it
    end

    # Dive takes the player from deep water to the same tile of the map below (its
    # DiveMap; Game_Character#moveto wraps it into a smaller map). Surfacing brings it
    # back up to the same tile of the map the engine picks (the first whose DiveMap this
    # is), where that tile is deep. The game reports the arrival tile itself, so no
    # slack: a step off it could be a wall.
    def dive?(prev, map, x, y)
      pmap, px, py = prev
      down = @world.dive_map(pmap) == map && @world.deep?(pmap, px, py) && [x, y] == wrap(map, px, py)
      up   = @world.surface_map(pmap) == map && @world.deep?(map, px, py) && [x, y] == [px, py]
      down || up
    end

    def wrap(map, x, y)
      w, h = @world.dims(map)
      w.to_i.positive? && h.to_i.positive? ? [x % w, y % h] : [x, y]
    end

    # On (or a step past) a tile a warp on +pmap+ lands on, or a start / home / heal
    # tile (whiteout, Fly-return).
    def arrival?(pmap, map, x, y)
      @world.warp_dest?(pmap, map, x, y, reach: ARRIVAL_REACH) ||
        @world.spawn_tile?(map, x, y, reach: ARRIVAL_REACH)
    end

    def log_violation(account_id, env, map, x, y, prev, verdict)
      pm, px, py = (prev || [])
      # Bound EVERY interpolated field: x/y/map are validated Integers but a client
      # can send a multi-KB bignum coordinate, so trunc them too (not just :mode).
      @log.call("posaudit: account #{account_id} #{verdict} " \
                "#{trunc(pm)}(#{trunc(px)},#{trunc(py)})->#{trunc(map)}(#{trunc(x)},#{trunc(y)}) " \
                "mode=#{trunc(env[:mode])}")
    end

    def log_enforce(account_id, map, x, y, prev, action)
      pm, px, py = (prev || [])
      @log.call("posenforce[#{@mode}]: account #{account_id} #{action} " \
                "#{trunc(map)}(#{trunc(x)},#{trunc(y)}) -> #{trunc(pm)}(#{trunc(px)},#{trunc(py)})")
    end

    def trunc(v)
      v.to_s[0, 24]
    end
  end
end
