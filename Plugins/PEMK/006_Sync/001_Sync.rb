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

    @econ        = {}           # field => latest absolute value (coalesced; badges ride here as a :badges bitmask)
    @inv_dirty   = false        # bag changed since the last flush -> re-read the WHOLE bag once at flush
    @mon_dirty   = false        # monsters may need uids / the party projection may have changed
    @mon_last    = nil          # hash of the last-sent party projection (send only on change)
    @seq         = Hash.new(0)  # channel => monotonic seq (adopted from the server on login)
    @dirty_since = nil
    @last_change = nil
    @blob_at     = -1.0e18
    @blob_hash   = nil

    module_function

    # Clear all client-side sync state (call on (re)connect: a socket the server
    # does not share must never keep stale dedup/seq baselines — see design §10).
    def reset
      @econ = {}
      @inv_dirty = false
      @mon_dirty = false
      @mon_last = nil
      (PEMK::Monsters.reset rescue nil)
      (PEMK::Trade.reset rescue nil)   # a fresh socket must abandon any in-flight trade
      (PEMK::Pickup.reset rescue nil)  # ... and any pending pickup grant + advertised flag
      @seq = Hash.new(0)
      @dirty_since = nil
      @last_change = nil
      @blob_at = -1.0e18
      @blob_hash = nil
    end

    # Adopt the server's canonical next-seq authority on (re)connect (from the
    # login_ok/auth_ok snapshot): the client's next :econ send continues past the
    # server's last recorded seq, so a replay across a reconnect can neither collide
    # with a consumed seq nor be silently deduped against one. Call AFTER reset.
    def adopt_econ_seq(n)
      @seq[:economy] = n if n.is_a?(Integer) && n > @seq[:economy]
    end

    # Twin of adopt_econ_seq for the independent :inv channel (bag snapshots).
    def adopt_inv_seq(n)
      @seq[:inv] = n if n.is_a?(Integer) && n > @seq[:inv]
    end

    # Twin for the :mon_party projection channel. (:uid_req needs NO adoption — its
    # seq is log-correlation only; mint idempotency lives in the persisted nonce.)
    def adopt_mon_seq(n)
      @seq[:mon] = n if n.is_a?(Integer) && n > @seq[:mon]
    end

    # --- OBSERVER entry points (called from the mutation aliases) ---------------
    # Every T1 mutation ALSO arms a blob checkpoint (flag-only, bounded by the 20s
    # floor + safety gate): T1 state reaches the server in ~0.5s while story flags
    # wait for the next checkpoint, so without this an event that grants an item
    # and sets a flag had a dupe window (kill -> item restored server-side, flag
    # rolled back -> event replayable). Arming here shrinks that skew to <=~20s;
    # the direction is always dupe-not-loss (commit flushes T1 BEFORE the write,
    # so the blob can never be AHEAD of the server). Full fix = M4 server-side
    # event execution.
    def mark_econ(field, value)
      return unless value.is_a?(Integer)

      @econ[field] = value
      touch
      (PEMK::Checkpoint.request(:t1) rescue nil)
    end

    # Bag mutation: flag-only (the whole bag is re-read once at flush, not per op —
    # a loop of 500 adds costs 500 flag-sets, one snapshot).
    def mark_inv
      @inv_dirty = true
      touch
      (PEMK::Checkpoint.request(:t1) rescue nil)
    end

    # Monster channel: uid sweep + party projection at the next flush. Flag-only;
    # the sweep is microseconds and the projection is hash-gated, so cheap to mark.
    # Also arms a checkpoint: a freshly granted uid/nonce must reach the blob soon
    # or a quit-without-save re-mints it as an orphan row (the VENUSAUR case).
    def mark_mon
      @mon_dirty = true
      touch
      (PEMK::Checkpoint.request(:t1) rescue nil)
    end

    def dirty?
      !@econ.empty? || @inv_dirty || @mon_dirty
    end

    # --- EVENT: flush now (map change, battle end, menu/scene close, quit) ------
    # Every event flush also sweeps the monster channel (new catches between events
    # are covered by the latency aliases; this is the self-healing catch-all).
    def flush_event(_reason = nil)
      @mon_dirty = true
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
      # Bag: one whole-bag read HERE (game thread), sent as an absolute snapshot.
      # An empty bag ({}) is a valid send; only a nil (no $bag yet) keeps the flag.
      if @inv_dirty
        bag = PEMK::Inventory.full_bag
        if bag
          c.send_message({ :type => :inv, :bag => bag, :seq => (@seq[:inv] += 1) })
          @inv_dirty = false
        end
      end
      # Monsters: (a) mint sweep — one <=64-entry :uid_req chunk per pass; a legacy
      # save with hundreds of mons drains over successive flushes (self-healing);
      # (b) party projection, sent only when it actually changed (hash gate).
      if @mon_dirty
        entries, more = PEMK::Monsters.pending_batch
        if entries && !entries.empty?
          c.send_message({ :type => :uid_req, :mons => entries, :seq => (@seq[:uid] += 1) })
        end
        # Don't project the party mid-trade: it is transiently changing (the mon
        # we're about to lose / the foreign one we're about to gain). The post-trade
        # mark_mon re-flushes the settled party.
        unless (PEMK::Trade.busy? rescue false)
          proj = PEMK::Monsters.projection
          if proj && proj.hash != @mon_last
            c.send_message({ :type => :mon_party, :mons => proj, :seq => (@seq[:mon] += 1) })
            @mon_last = proj.hash
          end
        end
        @mon_dirty = more ? true : false   # stay dirty while mints remain pending
      end
      @econ = {}
      # If a channel is still dirty (e.g. the bag couldn't be read this pass so
      # @inv_dirty stayed set), keep the debounce/staleness clocks armed so tick()
      # retries — resetting them unconditionally would strand the pending snapshot.
      unless dirty?
        @dirty_since = nil
        @last_change = nil
      end
    end

    # Push the full save blob, but only when it actually changed (content hash) and
    # not more often than BLOB_MIN_INTERVAL unless +force+ (a manual Game.save).
    # Returns a status symbol (:offline / :throttled / :unchanged / :pushed) so the
    # Checkpoint push-retry loop can tell "done" from "try again"; existing callers
    # ignore the return.
    def push_blob(save_file, force: false)
      c = PEMK.client
      return :offline unless c && c.connected? && File.file?(save_file)

      now = mono
      return :throttled if !force && (now - @blob_at) < BLOB_MIN_INTERVAL

      raw = File.binread(save_file)
      h = raw.hash
      return :unchanged if h == @blob_hash   # unchanged since the last push -> skip

      c.send_message({ :type => :save, :seq => (@seq[:save] += 1) }, raw)
      @blob_hash = h
      @blob_at = now
      PEMK.log("sync: pushed save blob (#{raw.bytesize}B, seq #{@seq[:save]})")
      :pushed
    rescue => e
      PEMK.log("sync: blob push failed: #{e.class}: #{e.message}")
      :offline
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
