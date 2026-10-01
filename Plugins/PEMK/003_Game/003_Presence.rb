#===============================================================================
# PEMK :: Presence
#-------------------------------------------------------------------------------
# Builds and emits the local player's presence (map, tile, direction, movement
# mode, charset). #emit is called from the step/turn EventHandlers and is
# de-duplicated (a turn + step for the same move won't send twice). #heartbeat
# re-announces the position periodically so late joiners still see idle players.
#===============================================================================
module PEMK
  module Presence
    @last_key = nil
    @hb = 0
    @v2   = false   # the server keeps idle players to itself and sends leaves (login flag)
    @sync = 0       # the remotes were cleared: the next frames ask who is on the map
    @since = 0      # frames since the last presence frame left

    # A frame now and then even while moving (presence v2): a forced walk sends no step,
    # and a map member silent for 15 s leaves it on the server.
    KEEPALIVE_FRAMES = 300

    def self.adopt_v2(value)
      @v2 = value == true
    end

    def self.v2?
      @v2
    end

    # The next frames ask who is on the map - three, as the server may drop one (its
    # rate budget) or refuse it (a snap-back); it answers one at most every few seconds.
    SYNC_FRAMES = 3

    def self.request_sync
      @sync = SYNC_FRAMES
    end

    # Every presence frame leaves through here: the first ones after a clear ask for
    # the server's snapshot of the map.
    def self.send_frame(h)
      if @sync > 0 && @v2
        h[:sync] = true
        @sync -= 1
      end
      @since = 0
      PEMK.send_message(h)
    end

    # Mirrors the priority in Game_Player#pbUpdateVehicle (008_Game_Player.rb:575);
    # "run" has no persistent flag, it's inferred from move_speed > 3.
    def self.movement_mode
      return :dive if $PokemonGlobal&.diving
      return :surf if $PokemonGlobal&.surfing
      return :bike if $PokemonGlobal&.bicycle
      return :run  if $game_player.move_speed && $game_player.move_speed > 3
      :walk
    end

    def self.build(type)
      {
        :type   => type,
        :id     => PEMK.self_id,
        :map    => $game_player.map_id,
        :x      => $game_player.x,
        :y      => $game_player.y,
        :dir    => $game_player.direction,
        :speed  => $game_player.move_speed,   # so the remote glides at OUR rate
        :mode   => movement_mode,
        :char   => $game_player.character_name,
        :outfit => ($player ? $player.outfit : 0),
        :name   => ($player ? $player.name : "")
      }
    end

    def self.can_emit?
      c = PEMK.client
      # self_id stays nil until the dedicated server authenticates us, so we never
      # emit presence pre-login (the server would drop an unauthenticated frame).
      c && c.connected? && $game_player && $game_map && PEMK.self_id
    end

    def self.key_of(h)
      [h[:map], h[:x], h[:y], h[:dir], h[:char]]
    end

    def self.emit(type)
      return unless can_emit?
      h = build(type)
      k = key_of(h)
      return if k == @last_key
      @last_key = k
      send_frame(h)
    end

    # A position the server must have now (a prize claim is judged by it): sent even
    # when it did not change since the last one.
    def self.emit_now(type)
      @last_key = nil
      emit(type)
    end

    # Ask for a fresh position broadcast on the next idle frame. Used on map
    # entry: emitting there directly would send a stale position (the transfer
    # hasn't finalised $game_player's tile yet), so we defer to the heartbeat,
    # which reads the live position once things have settled.
    def self.announce_soon
      @last_key = nil
      @hb = Config::HEARTBEAT_FRAMES
    end

    # Periodic re-announce so late joiners see idle players. Only fires while the
    # local player is standing still, so it never fights the per-step updates
    # that drive smooth remote walking - but under presence v2 one goes out every
    # KEEPALIVE_FRAMES even while moving: a forced walk sends no step.
    def self.heartbeat
      return unless can_emit?
      @since += 1
      if $game_player.moving?
        return unless @v2 && @since >= KEEPALIVE_FRAMES
      else
        @hb += 1
        return if @hb < Config::HEARTBEAT_FRAMES
      end
      @hb = 0
      h = build(:pos)
      @last_key = key_of(h)
      send_frame(h)
    end
  end
end
