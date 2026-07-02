#===============================================================================
# PEMK :: Sync  (client state-sync layer — M2.0 scaffolding)
#-------------------------------------------------------------------------------
# The client half of server authority (Milestone 2). Turns the existing mutation
# observers (money=/coins=/badge/... aliases) into a coalescing DIRTY-SET, and a
# debounce + event SCHEDULER flushes it to the server as compact primitive frames
# — instead of one socket write per mutation — plus content-hash + interval
# THROTTLED full-blob (:save) pushes instead of 90 KB on every save.
#
# Patterns: OBSERVER (the aliases call mark_*), FILTER (per-channel coalescing —
# economy/badges keep only the latest absolute value), EVENT (flush on game
# events + quiescence, driven off the per-frame Pump), STATE (per-channel seq;
# the full clean->dirty->in-flight->acked FSM with retries lands in M2.1 once the
# server actually acks — in M2.0 the server still ignores T1 frames, so this is a
# pure net win: far less traffic and no redundant blob pushes).
#===============================================================================
module PEMK
  module Sync
    DEBOUNCE_FRAMES   = 30      # ~0.5 s of quiescence before an idle flush
    STALENESS_FRAMES  = 300     # ~5 s hard cap: never hold a dirty change longer
    BLOB_MIN_INTERVAL = 30.0    # seconds between throttled (non-forced) blob pushes

    @econ        = {}           # field => latest absolute value (coalesced)
    @badge       = {}           # index => owned bool (coalesced)
    @seq         = Hash.new(0)  # channel => monotonic seq (local until M2.1 adopts server seq)
    @dirty_since = nil
    @last_change = nil
    @blob_at     = -1.0e18
    @blob_hash   = nil

    module_function

    # Clear all client-side sync state (call on (re)connect: a socket the server
    # does not share must never keep stale dedup/seq baselines — see design §10).
    def reset
      @econ = {}
      @badge = {}
      @seq = Hash.new(0)
      @dirty_since = nil
      @last_change = nil
      @blob_at = -1.0e18
      @blob_hash = nil
    end

    # --- OBSERVER entry points (called from the mutation aliases) ---------------
    def mark_econ(field, value)
      return unless value.is_a?(Integer)

      @econ[field] = value
      touch
    end

    def mark_badge(index, owned)
      return unless index.is_a?(Integer)

      @badge[index] = (owned ? true : false)
      touch
    end

    def dirty?
      !@econ.empty? || !@badge.empty?
    end

    # --- EVENT: flush now (map change, battle end, menu/scene close, quit) ------
    def flush_event(_reason = nil)
      flush_primitives
    end

    # --- per-frame tick (from Pump): debounce + staleness cap ------------------
    def tick
      return unless dirty?

      fc = frame
      quiescent = @last_change && (fc - @last_change) >= DEBOUNCE_FRAMES
      stale     = @dirty_since && (fc - @dirty_since) >= STALENESS_FRAMES
      flush_primitives if quiescent || stale
    end

    # Send the coalesced primitive channels as one frame each, then clear.
    def flush_primitives
      c = PEMK.client
      return unless c && c.connected? && dirty?

      @econ.each do |field, value|
        c.send_message({ :type => :econ, :field => field, :value => value, :seq => (@seq[:economy] += 1) })
      end
      @badge.each do |index, owned|
        c.send_message({ :type => :badge, :index => index, :owned => owned, :seq => (@seq[:badge] += 1) })
      end
      @econ = {}
      @badge = {}
      @dirty_since = nil
      @last_change = nil
    end

    # Push the full save blob, but only when it actually changed (content hash) and
    # not more often than BLOB_MIN_INTERVAL unless +force+ (an explicit Game.save).
    def push_blob(save_file, force: false)
      c = PEMK.client
      return unless c && c.connected? && File.file?(save_file)

      now = mono
      return if !force && (now - @blob_at) < BLOB_MIN_INTERVAL

      raw = File.binread(save_file)
      h = raw.hash
      return if h == @blob_hash   # unchanged since the last push -> skip

      c.send_message({ :type => :save, :seq => (@seq[:save] += 1) }, raw)
      @blob_hash = h
      @blob_at = now
      PEMK.log("sync: pushed save blob (#{raw.bytesize}B, seq #{@seq[:save]})")
    rescue => e
      PEMK.log("sync: blob push failed: #{e.class}: #{e.message}")
    end

    def touch
      fc = frame
      @dirty_since ||= fc
      @last_change = fc
    end

    def frame
      Graphics.frame_count
    rescue StandardError
      0
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end
