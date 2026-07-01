#===============================================================================
# PokeMMO :: Presence
#-------------------------------------------------------------------------------
# Builds and emits the local player's presence (map, tile, direction, movement
# mode, charset). #emit is called from the step/turn EventHandlers and is
# de-duplicated (a turn + step for the same move won't send twice). #heartbeat
# re-announces the position periodically so late joiners still see idle players.
#===============================================================================
module PokeMMO
  module Presence
    @last_key = nil
    @hb = 0

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
        :id     => PokeMMO.self_id,
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
      c = PokeMMO.client
      c && c.connected? && $game_player && $game_map
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
      PokeMMO.send_message(h)
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
    # that drive smooth remote walking.
    def self.heartbeat
      return unless can_emit?
      return if $game_player.moving?
      @hb += 1
      return if @hb < Config::HEARTBEAT_FRAMES
      @hb = 0
      h = build(:pos)
      @last_key = key_of(h)
      PokeMMO.send_message(h)
    end
  end
end
