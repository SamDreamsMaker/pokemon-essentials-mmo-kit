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
  class Audit
    def initialize(world, logger: nil)
      @world = world
      @log   = logger || ->(_m) {}
    end

    # Verdict symbols:
    #   :match         claim agrees with the world model (silent)
    #   :item_mismatch an object is there but a different item
    #   :no_object     nothing at that tile in the model
    #   :unknown_map   the map isn't in the export (drift / instance / new map)
    #   :unchecked     no world exported yet -> nothing to compare against (silent)
    #   :bad           malformed claim primitives (silent — not a cheat signal)
    # Logs on any real mismatch; silent on match / unchecked / bad.
    def check_interaction(account_id, env)
      map = env[:map]; x = env[:x]; y = env[:y]
      return :bad unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      # No world exported yet -> nothing to check against (don't flag everything).
      return :unchecked if @world.empty?

      item    = env[:item]
      verdict = classify(map, x, y, item)
      return :match if verdict == :match

      # Every interpolated field is client-supplied. kind/item/px/py are unvalidated;
      # map/x/y are Integers but can be multi-KB bignums. Truncate them all so a
      # malicious frame can't write a giant log line.
      @log.call("audit: account #{account_id} interact #{verdict} " \
                "kind=#{trunc(env[:kind])} item=#{trunc(item)} " \
                "at (#{trunc(map)},#{trunc(x)},#{trunc(y)}) from (#{trunc(env[:px])},#{trunc(env[:py])})")
      verdict
    rescue StandardError => e
      # An audit must never take down the reactor thread it runs on.
      @log.call("audit: check error #{e.class}: #{e.message}")
      :bad
    end

    private

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
