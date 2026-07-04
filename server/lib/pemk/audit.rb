# frozen_string_literal: true

module PEMK
  # Detection-only interaction audit (Milestone 4, Layer A). The client reports each
  # gameplay interaction it performed ("I picked up item X at (map,x,y) from position
  # (px,py)"); we look the claim up in the read-only WorldData and LOG a mismatch. We
  # NEVER reject, reply, or mutate — exactly the shape of Inventory#log_divergence.
  # This is telemetry that seeds the enforcement layers (B/C/D) with real data and a
  # false-positive signal BEFORE anything ever blocks a player.
  #
  # Identity is ALWAYS the server-trusted account_id from the authenticated
  # connection, never a client-supplied :id (the handle_presence anti-spoof rule).
  #
  # Milestone 4 Layer C adds an INTERACTION-DISTANCE check: a valid pickup must also
  # be within reach of the player's SERVER-tracked position (conn.data[:last_pos],
  # maintained by Layer B) — NOT the client-claimed px/py, which a cheat can fake.
  # This catches remote pickups (claiming an item far from where the server thinks
  # you are). Still detection-only.
  class Audit
    INTERACT_MAX_DIST = 1   # you pick up an item you're standing on (0) or facing (1)

    def initialize(world, logger: nil)
      @world = world
      @log   = logger || ->(_m) {}
    end

    # Verdict symbols:
    #   :match         claim agrees with the world model + in reach (silent)
    #   :item_mismatch an object is there but a different item
    #   :no_object     nothing at that tile in the model
    #   :unknown_map   the map isn't in the export (drift / instance / new map)
    #   :too_far       object exists + matches, but it's out of the player's reach (L-C)
    #   :unchecked     no world exported yet -> nothing to compare against (silent)
    #   :bad           malformed claim primitives (silent — not a cheat signal)
    # Logs on any real mismatch; silent on match / unchecked / bad.
    # player_pos is the server-tracked [map,x,y] (nil -> skip the distance check).
    def check_interaction(account_id, env, player_pos = nil)
      map = env[:map]; x = env[:x]; y = env[:y]
      return :bad unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      # No world exported yet -> nothing to check against (don't flag everything).
      return :unchecked if @world.empty?

      item    = env[:item]
      verdict = classify(map, x, y, item)
      # Layer C: an existing, item-matching object is only a real pickup if the player
      # is actually next to it (server position, not client-claimed).
      verdict = :too_far if verdict == :match && player_pos && too_far?(player_pos, map, x, y)
      return :match if verdict == :match

      log_claim(account_id, env, map, x, y, item, verdict, player_pos)
      verdict
    rescue StandardError => e
      # An audit must never take down the reactor thread it runs on.
      @log.call("audit: check error #{e.class}: #{e.message}")
      :bad
    end

    private

    # Chebyshev distance from the server-tracked player tile to the object; a
    # different map, or a malformed position, counts as out of reach.
    def too_far?(player_pos, map, x, y)
      pm, px, py = player_pos
      return true unless pm.is_a?(Integer) && px.is_a?(Integer) && py.is_a?(Integer)
      return true if pm != map

      [(x - px).abs, (y - py).abs].max > INTERACT_MAX_DIST
    end

    # Every interpolated field is client-supplied (map/x/y are Integers but can be
    # multi-KB bignums); truncate them all so a malicious frame can't write a giant
    # log line. A :too_far line reports the SERVER position it was judged against.
    def log_claim(account_id, env, map, x, y, item, verdict, player_pos)
      line = "audit: account #{account_id} interact #{verdict} " \
             "kind=#{trunc(env[:kind])} item=#{trunc(item)} at (#{trunc(map)},#{trunc(x)},#{trunc(y)})"
      line += if verdict == :too_far && player_pos
                pm, px, py = player_pos
                " server_pos=(#{trunc(pm)},#{trunc(px)},#{trunc(py)})"
              else
                " from (#{trunc(env[:px])},#{trunc(env[:py])})"
              end
      @log.call(line)
    end

    # Bound any client-supplied value before it reaches the log.
    def trunc(v)
      v.to_s[0, 32]
    end

    def classify(map, x, y, item)
      return :unknown_map unless @world.map_known?(map)

      obj = @world.object_at(map, x, y)
      return :no_object if obj.nil?
      # Only compare when both sides name an item; a tile-less/item-less object
      # (a future warp/heal tile) is a positional match, not an item claim.
      return :item_mismatch if item && obj["item"] && obj["item"].to_s != item.to_s

      :match
    end
  end
end
