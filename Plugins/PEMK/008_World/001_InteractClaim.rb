#===============================================================================
# PEMK :: InteractClaim  (client side — M4 Layer A, AUDIT-ONLY)
#-------------------------------------------------------------------------------
# The first "server-authoritative gameplay" seam. When the player picks up an
# overworld item ball, we report a DISCRETE claim to the server — "I picked up
# <item> at (map,x,y) from my position (px,py)" — which the server checks against
# its read-only world model and LOGS if it disagrees. Nothing is enforced yet:
# this is telemetry that seeds the later enforcement layers (B position,
# C interaction-distance, D battle) with real data + a false-positive signal.
#
# WHY AN ALIAS, NOT AN OBSERVER: a pickup is a discrete event, not coalescable
# state, so it is sent INLINE via PEMK.send_message and deliberately does NOT go
# through Sync's dirty-set (which would collapse two pickups into one). Same
# guarded top-level alias idiom as 004_Persist/006_Monsters.rb — no core edit.
#
# COORDINATES: the object's own tile comes from the running map event
# ($game_map.events[@event_id]); @event_id is read defensively. A pickup from an
# AUTORUN/standalone common event has @event_id 0 -> tile nil -> the server treats
# it as un-locatable. (A pickup inside a common event *called* from a map event is
# attributed to the CALLING event's tile, because the map interpreter keeps that
# @event_id — a rare authoring pattern that may produce a spurious audit line;
# harmless under audit-only, and Layer C can tighten it.) Player position rides
# along for the distance checks Layer C will add.
#===============================================================================

module PEMK
  module InteractAudit
    module_function

    # Called after a SUCCESSFUL pbItemBall. Best-effort + never raises into the
    # engine: a telemetry frame must never disturb a pickup.
    def on_item_pickup(item, _quantity = 1)
      # Not authenticated yet? Stay silent. The server drops ANY non-auth frame on an
      # unauthenticated socket (setting conn.closing = true), so emitting a claim
      # before login completes would disconnect the player and churn the reconnect
      # FSM on every pickup. Mirror Presence.can_emit?'s `&& PEMK.self_id` gate.
      return unless PEMK.self_id

      map = ($game_map && $game_map.map_id) or return
      tile = current_event_tile   # [x, y] | nil
      PEMK.send_message(
        :type => :interact_claim,
        :kind => :item,
        :item => normalize_item(item),
        :map  => map,
        :x    => (tile ? tile[0] : nil),
        :y    => (tile ? tile[1] : nil),
        :px   => ($game_player ? $game_player.x : nil),
        :py   => ($game_player ? $game_player.y : nil)
      )
    rescue => e
      PEMK.log("audit: on_item_pickup error #{e.class}: #{e.message}")
    end

    # The tile of the event whose script triggered the pickup. Read @event_id off
    # the running map interpreter (visibility-proof vs. the possibly-private
    # get_character). -> [x, y] | nil.
    def current_event_tile
      interp = (pbMapInterpreter rescue nil)
      return nil unless interp

      eid = interp.instance_variable_get(:@event_id)
      return nil unless eid.is_a?(Integer) && eid != 0
      return nil unless $game_map && $game_map.events

      ev = $game_map.events[eid]
      return nil unless ev

      [ev.x, ev.y]
    rescue
      nil
    end

    # The raw item argument may be a Symbol (:POTION) or a GameData::Item; the
    # server compares against the symbol string the exporter captured from the map
    # script, so normalise to the canonical id symbol.
    def normalize_item(item)
      return item if item.is_a?(Symbol)
      return item.id if item.respond_to?(:id)

      item
    end
  end
end

# --- guarded top-level alias: emit a claim on a successful item-ball pickup ------
unless defined?(pemk_orig_pbItemBall)
  alias pemk_orig_pbItemBall pbItemBall
  def pbItemBall(item, quantity = 1)
    # M4 Layer C: when the server enforces pickups, ASK before taking (server-mint).
    # Otherwise (offline / solo / pre-login / flag-off) keep the local pickup and the
    # detection-only claim. Exactly one of {grant request, claim} fires per pickup.
    if (PEMK::Pickup.enforce? rescue false)
      PEMK::Pickup.gated_pickup(item, quantity) { |i, q| pemk_orig_pbItemBall(i, q) }
    else
      got = pemk_orig_pbItemBall(item, quantity)
      (PEMK::InteractAudit.on_item_pickup(item, quantity) if got) rescue nil
      got
    end
  end
end
