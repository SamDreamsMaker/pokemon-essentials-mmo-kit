#===============================================================================
# PEMK :: RemotePlayer + Remotes registry
#-------------------------------------------------------------------------------
# RemotePlayer is a minimal Game_Character used to draw another player on the
# map. @through = true so it follows server truth and never gets stuck on local
# collision/passability. It reuses the engine's own tile interpolation
# (move_generic -> update_move lerp) so remote movement is smooth for free.
#
# Remotes keeps the id -> RemotePlayer table (survives across the frame) and the
# id -> Sprite_Character table (tied to the current Spriteset_Map). Sprites are
# injected via Spriteset_Map#addUserSprite, which updates and disposes them for
# us; we only reattach when a new spriteset is (re)built (map change).
#===============================================================================
module PEMK
  class RemotePlayer < Game_Character
    attr_reader   :player_id
    attr_accessor :player_name

    def initialize(player_id, map = nil)
      super(map)
      @player_id  = player_id
      @through    = true      # follow server truth, ignore local passability
      @walk_anime = true
      self.move_speed = 4
    end

    # Core sprite code (Sprite_Character#initialize) calls #name on the character
    # to detect "reflection" events; Game_Character has no #name, which raised a
    # (rescued but debug-logged) NoMethodError. Expose our display name instead —
    # a normal name never matches /reflection/i, so behaviour is unchanged.
    def name
      @player_name.to_s
    end

    # Hard place / teleport: snaps to the tile with no interpolation.
    def spawn_at(x, y, dir, charset, hue = 0)
      self.character_name = charset.to_s if charset && !charset.to_s.empty?
      self.character_hue  = hue || 0
      moveto(x, y)
      @direction = dir if [2, 4, 6, 8].include?(dir)
    end

    # Walk one tile in +dir+ (2/4/6/8), arming the engine's native lerp.
    def step_towards(dir)
      return if moving? || jumping?
      case dir
      when 2 then move_down(false)
      when 4 then move_left(false)
      when 6 then move_right(false)
      when 8 then move_up(false)
      end
      @direction = dir if [2, 4, 6, 8].include?(dir)
    end

    # Collapse an in-progress glide to its destination tile (used to chain steps
    # without falling behind when position updates arrive faster than one glide).
    def finish_step
      @real_x = @x * Game_Map::REAL_RES_X
      @real_y = @y * Game_Map::REAL_RES_Y
      @move_timer = nil
      @jump_timer = nil
    end
  end

  module Remotes
    @players   = {}    # pid => RemotePlayer
    @sprites   = {}    # pid => Sprite_Character (current spriteset)
    @last_seen = {}    # pid => System.uptime of the last message (for timeout)
    @viewport  = nil   # @@viewport1 from the last :on_new_spriteset_map

    def self.players;        @players;                                end
    def self.current_map_id; $game_map ? $game_map.map_id : nil;      end

    def self.get_or_create(pid)
      @players[pid] ||= RemotePlayer.new(pid, $game_map)
    end

    # Apply a position/direction update from the network.
    def self.apply_pos(msg)
      pid = msg[:id]
      return unless pid
      # Only show players on our current map; drop anyone who left it.
      if msg[:map] && current_map_id && msg[:map] != current_map_id
        remove(pid)
        return
      end
      rp = get_or_create(pid)
      @last_seen[pid] = (System.uptime rescue 0.0)
      rp.player_name = msg[:name] if msg[:name] && !msg[:name].to_s.empty?
      sp = msg[:speed]                 # glide at the sender's real speed (anti-burst)
      rp.move_speed = sp if sp.is_a?(Numeric) && sp > 0 && rp.move_speed != sp
      cs = msg[:char]
      rp.character_name = cs.to_s if cs && !cs.to_s.empty?
      tx = msg[:x].to_i
      ty = msg[:y].to_i
      tdir = msg[:dir]
      dx = tx - rp.x
      dy = ty - rp.y
      if dx == 0 && dy == 0
        # Turn in place: only update facing. Do NOT collapse an in-progress glide
        # here — doing so snapped the sprite forward and looked like a teleport
        # whenever the player changed direction.
        rp.direction = tdir if [2, 4, 6, 8].include?(tdir)
      elsif dx.abs + dy.abs == 1
        rp.finish_step if rp.moving?     # collapse the current glide, then chain the next
        sd = dx == 1 ? 6 : (dx == -1 ? 4 : (dy == 1 ? 2 : 8))
        rp.step_towards(sd)              # glide one tile
        rp.direction = tdir if [2, 4, 6, 8].include?(tdir)
      else
        rp.spawn_at(tx, ty, tdir, cs)    # far jump: snap (teleport/desync recovery)
      end
      attach_current(pid)
    end

    def self.attach_current(pid)
      return unless $scene.is_a?(Scene_Map)
      ss = ($scene.spriteset rescue nil)
      attach_sprite(pid, ss, @viewport) if ss && @viewport
    end

    def self.attach_sprite(pid, spriteset, viewport)
      return unless spriteset && viewport
      old = @sprites[pid]
      return if old && !old.disposed?
      rp = @players[pid]
      return unless rp
      spr = Sprite_Character.new(viewport, rp)
      @sprites[pid] = spr
      spriteset.addUserSprite(spr)     # engine updates + disposes it for us
    end

    # A fresh spriteset was built (map load / transfer): the old user sprites are
    # already disposed, so drop stale refs and reattach every known remote.
    def self.on_new_spriteset(spriteset, viewport)
      @viewport = viewport
      return unless spriteset && spriteset.map == $game_map
      @sprites.clear
      @players.keys.each { |pid| attach_sprite(pid, spriteset, viewport) }
    end

    def self.remove(pid)
      s = @sprites[pid]
      (s.dispose if s && !s.disposed?) rescue nil
      @sprites.delete(pid)
      @players.delete(pid)
      @last_seen.delete(pid)
    end

    # Drop remotes we haven't heard from for PRESENCE_TIMEOUT seconds (handles
    # disconnects/crashes — the dumb relay doesn't send leave events).
    def self.prune
      return if @players.empty?
      now = (System.uptime rescue nil)
      return unless now
      @players.keys.each do |pid|
        ls = @last_seen[pid]
        remove(pid) if ls && (now - ls) > Config::PRESENCE_TIMEOUT
      end
    end

    def self.dispose_sprites
      @sprites.each_value { |s| (s.dispose if s && !s.disposed?) rescue nil }
      @sprites.clear
    end

    def self.clear_all
      dispose_sprites
      @players.clear
      @last_seen.clear
    end

    # Advance interpolation/animation for every remote each frame.
    def self.update_all
      @players.each_value { |rp| (rp.update) rescue nil }
    end
  end
end
