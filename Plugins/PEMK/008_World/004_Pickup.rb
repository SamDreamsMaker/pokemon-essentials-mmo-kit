#===============================================================================
# PEMK :: Pickup  (client side — M4 Layer C, server-minted item pickups)
#-------------------------------------------------------------------------------
# When the SERVER enforces pickups (advertised in the login snapshot), an overworld
# item ball must be GRANTED before the client adds it: the guarded pbItemBall alias
# (001_InteractClaim.rb) calls gated_pickup, which sends a :pickup_req and BLOCKS a
# bounded time — pumping the overworld frame loop like pbWait, so the network keeps
# flowing and the grant/deny is dispatched here — then calls the original pickup on
# :pickup_grant, or leaves the ball on :pickup_deny / timeout.
#
# The client only gates when it KNOWS the server is enforcing AND it is online +
# authenticated; otherwise (offline / solo / pre-login / flag-off / tile-less / bag
# full) it does the normal local pickup, so nothing changes until an operator opts
# in. A timeout / dropped link leaves the ball for a later retry — NOT a local
# fallback, so induced packet loss can't bypass enforcement.
#
# HONEST caveat: the server consumes the one-shot at GRANT time, so if a grant is
# LOST (timeout on a bad link, or a drop in the request->grant window) that one item
# is forfeited — the retry gets already_taken. This deliberately favours anti-DUPE
# over anti-loss; the bag is blob-authoritative (M2.3), so true minted-into-inventory
# with exactly-once delivery is deferred to the server-authoritative-bag milestone.
#===============================================================================
module PEMK
  module Pickup
    @enforce = false   # server-advertised enforcement mode (adopted at login)
    @seq     = 0       # client-local request id, to correlate reply -> pickup
    @inbox   = {}      # seq => reply hash (delete-on-read)

    module_function

    # Called from Sync.reset on (re)connect — a fresh socket keeps no stale replies.
    def reset
      @enforce = false
      @seq     = 0
      @inbox   = {}
    end

    # Adopt the server's advertised mode from the login/auth snapshot.
    def adopt_enforce(v)
      @enforce = (v == true)
    end

    # True only when we must ask the server first: it says on AND we're a live,
    # authenticated online client. Any false -> caller does the local pickup.
    def enforce?
      return false unless @enforce && PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # The gated pickup path. +blk+ is the original pbItemBall (adds + message +
    # returns true so the map event self-switches the ball away). -> boolean.
    def gated_pickup(item, quantity, &blk)
      # GATING phase — rescue-guarded, and calls NOTHING that mutates the bag: resolve
      # the object tile, skip the round-trip if the bag can't hold the item, request a
      # grant, and wait. A fault here degrades to a single LOCAL pickup.
      # -> :local | reply Hash | nil (timeout/dropped).
      outcome =
        begin
          map  = ($game_map && $game_map.map_id)
          tile = (PEMK::InteractAudit.current_event_tile rescue nil)   # [x,y] | nil
          if !(map && tile)                  # tile-less (autorun / common event / gift)
            :local
          elsif !can_hold?(item, quantity)   # bag full -> vanilla behaviour, don't burn the one-shot
            :local
          else
            wait_for(request(PEMK::InteractAudit.normalize_item(item), map, tile[0], tile[1]))
          end
        rescue StandardError => e
          PEMK.log("pickup: gate error #{e.class}: #{e.message}")
          :local
        end

      # APPLY phase — OUTSIDE the rescue, so blk runs AT MOST ONCE: a post-add
      # exception in pbItemBall propagates normally and can never cause a second
      # $bag.add (the anti-dupe layer must not itself dupe).
      return blk.call(item, quantity) if outcome == :local

      case outcome && outcome[:type]
      when :pickup_grant
        blk.call(item, quantity)   # vanilla add + "You found X" + returns true
      when :pickup_deny
        (pbMessage(_INTL("The Item Ball seems to be empty...")) if outcome[:reason].to_s == "already_taken") rescue nil
        false
      else
        false   # timeout / dropped link -> leave the ball (rare item-loss, see header)
      end
    end

    # Can the bag actually take this now? If not, skip the round-trip so the server
    # one-shot isn't consumed on a grant we couldn't apply (vanilla leaves a bag-full
    # ball for a later retry).
    def can_hold?(item, quantity)
      return true unless $bag && $bag.respond_to?(:can_add?)

      $bag.can_add?(item, quantity)
    rescue StandardError
      true
    end

    def request(item, map, x, y)
      @inbox.clear   # a new pickup supersedes any late reply from a timed-out one (no @inbox leak)
      @seq += 1
      PEMK.send_message(:type => :pickup_req, :kind => :item, :item => item,
                        :map => map, :x => x, :y => y, :seq => @seq)
      @seq
    end

    # Dispatch routes :pickup_grant / :pickup_deny here (delete-on-read by seq).
    def on_reply(msg)
      s = msg && msg[:seq]
      @inbox[s] = msg if s.is_a?(Integer)
    end

    def take(seq)
      @inbox.delete(seq)
    end

    # Block until the reply for +seq+ arrives or the deadline passes, pumping the
    # overworld loop (Graphics.update IS the SDK network pump). Aborts if the link
    # drops. -> reply hash | nil.
    def wait_for(seq)
      deadline = mono + Config::PICKUP_GRANT_TIMEOUT
      loop do
        r = take(seq)
        return r if r
        return nil if mono >= deadline

        c = PEMK.client
        return nil unless c && c.connected?

        Graphics.update           # advances the frame -> Pump.tick polls -> on_reply
        Input.update
        (pbUpdateSceneMap rescue nil)
      end
    rescue StandardError => e
      PEMK.log("pickup: wait error #{e.class}: #{e.message}")
      nil
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end
