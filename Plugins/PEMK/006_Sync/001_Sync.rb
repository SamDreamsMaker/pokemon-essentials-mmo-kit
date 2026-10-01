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
    SAVE_ACK_WAIT     = 30.0    # seconds for the server to say a pushed save was written
    SAVE_RETRY_FIRST  = 5.0     # a save not written goes out again after this; doubles each time
    SAVE_RETRY_MAX    = 60.0
    BLOB_CLAIMS_MAX   = 64      # prize claims a save names (the newest; the server keeps as many)
    BADGE_HOLD_SEC    = 60.0    # seconds at most a badge frame waits for its win's claim and record (B2);
                                # past a record's 30 s resend

    @econ        = {}           # field => latest absolute value (coalesced; badges ride here as a :badges bitmask)
    @econ_sent   = {}           # field => [seq, value] of its latest frame (an answer to an older one is stale)
    @inv_dirty   = false        # bag changed since the last flush -> re-read the WHOLE bag once at flush
    @mon_dirty   = false        # monsters may need uids / the party projection may have changed
    @mon_last    = nil          # hash of the last-sent party projection (send only on change)
    @flag_last   = nil          # hash of the last-sent switches/variables snapshot (send only on change)
    @flag_dirty  = false        # story state changed -> the flags channel alone can trigger a flush
    @team_last   = nil          # hash of the last-sent full-stat team (M4 Layer D legality; send on change)
    @seq         = Hash.new(0)  # channel => monotonic seq (adopted from the server on login)
    @dirty_since = nil
    @last_change = nil
    @blob_at     = -1.0e18
    @blob_hash   = nil
    @blob_fseq   = 0        # flags seq the on-disk blob was serialized at
    @blob_claims = nil      # the prize claim nonces the on-disk blob carries (nil: not known)
    @save_ack     = false   # the server answers each save written or not (login flag)
    @save_unacked = nil     # { :seq, :at } of the last pushed save, until its answer
    @save_retry   = SAVE_RETRY_FIRST
    @save_wait    = nil     # mono before which a save not written is not sent again
    @save_failing = false   # the player was told saves fail: tell them when one lands
    @badge_hold   = false   # the server owns the badges (login flag, B2): a badge frame waits for its win
    @badge_hold_since = nil # when the badges began waiting (monotonic)

    module_function

    # Clear all client-side sync state (call on (re)connect: a socket the server
    # does not share must never keep stale dedup/seq baselines — see design §10).
    def reset
      @econ = {}
      @econ_sent = {}
      @badge_hold = false
      @badge_hold_since = nil
      @inv_dirty = false
      @inv_last = nil
      @mon_dirty = false
      @mon_last = nil
      @flag_last = nil
      @flag_dirty = false
      @team_last = nil
      (PEMK::Monsters.reset rescue nil)
      (PEMK::Trade.reset rescue nil)   # a fresh socket must abandon any in-flight trade
      (PEMK::Pickup.reset rescue nil)  # ... and any pending pickup grant + advertised flag
      (PEMK::GiftClaim.reset rescue nil)  # ... and any gift reply + the advertised gift gate
      (PEMK::PeerPokemon.reset rescue nil) # ... and the advertised peer check
      (PEMK::TradeRedeliver.reset rescue nil)  # ... and any traded Pokemon still queued
      (PEMK::Shop.reset rescue nil)       # ... and the advertised shop gate
      (PEMK::Presence.announce_soon rescue nil)  # ... and the position it last sent: a new socket has none
      (PEMK::PrizeClaim.reset rescue nil) # ... and the advertised money claims (every claim goes out again)
      (PEMK::Encounter.reset rescue nil)  # ... and the advertised encounter mode (M4-D2)
      (PEMK::Catch.reset rescue nil)      # ... and the advertised catch mode (M4-D3)
      (PEMK::Reward.reset rescue nil)     # ... and the advertised reward mode (M4-D4)
      (PEMK::ExpCorrect.reset rescue nil) # ... and any pending EXP restore + mode (M4-D6)
      (PEMK::BattleRng.reset rescue nil)  # ... and any pending battle seed + mode (M4-D7)
      (PEMK::Challenge.clear_partner rescue nil)  # ... and the peer consent gate (a new socket agreed to nothing)
      (PEMK::Flags.reset rescue nil)      # ... and the advertised flag-shadow mode
      @seq = Hash.new(0)
      @dirty_since = nil
      @last_change = nil
      @blob_at = -1.0e18
      @blob_hash = nil
      @blob_fseq = 0
      @save_ack = false
      @save_unacked = nil
      @save_retry = SAVE_RETRY_FIRST
      @save_wait = nil
      @save_failing = false
    end

    # The server says it answers each save (login/auth flag). An older one never does:
    # its saves are trusted once sent, as before.
    def adopt_save_ack(v)
      @save_ack = v == true
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

    # E4: the seq of the last bag snapshot sent, and whether the possession changed since
    # (a correction applies only to the snapshot it was judged against).
    def inv_seq
      @seq[:inv]
    end

    def inv_dirty?
      @inv_dirty == true
    end

    # Checkpoint calls this right after a successful serialize: the bytes on disk now
    # contain every flag frame sent so far, so this seq is the blob's durability
    # watermark. It has to be stamped HERE and not at push time - the exit backstop
    # re-pushes the last good file, which can be older than the current flag state,
    # and claiming that seq would let the server hand back a switch the save lacks.
    # Starts at 0, so before any checkpoint the server promotes nothing.
    def mark_blob_watermark
      @blob_fseq = @seq[:flags]
      # Trainer proof P4: the prize claims these bytes carry - a claim held for its proof
      # is kept past a fresh login only by a save that has it. Unchanged by a reconnect
      # (the file is the same); unknown (nil) for a file from before this session.
      @blob_claims = (PEMK::PrizeClaim.claims.map(&:first).last(BLOB_CLAIMS_MAX) rescue nil)   # the newest
    end

    # Twin for the :flags channel. Without it, reset zeroes the seq on a new socket
    # and the server drops every later snapshot as stale — the channel goes silent
    # after the first reconnect.
    # The seq of the last :flags snapshot sent (a repair names the one it judged).
    def flags_seq
      @seq[:flags]
    end

    def adopt_flags_seq(n)
      @seq[:flags] = n if n.is_a?(Integer) && n > @seq[:flags]
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

    # Badge authority B2 (login flag): the server owns the badges.
    def adopt_badge_hold(v)
      @badge_hold = v == true
    end

    # B2: while a trainer prize claim or a battle record of this connection has no answer,
    # the badges wait - the server shows a badge once the win it comes from is in - at
    # most BADGE_HOLD_SEC (the clock, not frames: a sped-up game waits as long).
    def badges_waiting?
      return false unless @badge_hold

      waiting = (PEMK::PrizeClaim.unanswered? rescue false) || (PEMK::BattleRng.records_unacked? rescue false)
      unless waiting
        @badge_hold_since = nil
        return false
      end
      @badge_hold_since ||= mono
      mono - @badge_hold_since < BADGE_HOLD_SEC
    end

    # B2: after a claim's or a record's answer the badges go out again - the server answers
    # with what the client shows, the win just in included. No checkpoint.
    def remark_badges
      return unless @badge_hold && $player

      mask = ($player.pokemmo_badges_mask rescue nil)
      return unless mask.is_a?(Integer)

      @econ[:badges] = mask
      touch
    end

    # What an :econ_ack / :econ_rej leaves +field+ at, or nil to leave it alone. Only the
    # answer to the field's latest frame counts: an older one carries a balance a newer
    # frame already moved past. While a newer change waits to go out, the answer lands as
    # a delta on it - the change survives, corrected by what the server kept, and goes
    # out corrected - and a bitmask (badges) waits for that frame's own answer.
    def econ_reply(field, seq, value)
      sent = @econ_sent[field]
      return value unless sent
      return nil unless seq == sent[0]

      waiting = @econ[field]
      return value if waiting.nil?
      return nil if field == :badges

      @econ[field] = waiting + (value - sent[1])
    end

    # Story state (switches/variables/self-switches) moved. Flag-only: the whole
    # non-default set is re-read once at flush and hash-gated, exactly like the bag.
    def mark_flags
      @flag_dirty = true
      touch
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
      @inv_dirty = true   # a Pokemon that comes or goes brings or takes its held item
      touch
      (PEMK::Checkpoint.request(:t1) rescue nil)
    end

    def dirty?
      # @flag_dirty belongs here: without it a PURE story change (an event sets a
      # switch and nothing else moves) never flushed — the flags channel could only
      # ride along with another dirty channel.
      !@econ.empty? || @inv_dirty || @mon_dirty || @flag_dirty
    end

    # --- EVENT: flush now (map change, battle end, menu/scene close, quit) ------
    # Every event flush also sweeps the monster channel (new catches between events
    # are covered by the latency aliases; this is the self-healing catch-all).
    def flush_event(_reason = nil)
      @mon_dirty = true
      @inv_dirty = true   # every store, hash-gated: a held item or the PC can change alone
      flush_primitives
    end

    # --- per-frame tick (from Pump): debounce + staleness cap ------------------
    def tick
      watch_save_ack
      return unless dirty?
      # Nothing leaves mid-battle: the EXP a battle (or a catch) gives must reach the
      # server after the battle's end report, which opens the reward window it is
      # judged against. The post-battle checkpoint flushes it all.
      return if ($game_temp && $game_temp.in_battle rescue false)
      # Nor while a gift waits for its grant or its :gift_applied (step 6).
      return if (PEMK::GiftClaim.holding? rescue false)
      # Nor while a gated deal is in doubt (E3): its money and items wait for its outcome.
      return if (PEMK::Shop.holding? rescue false)

      fc = frame
      quiescent = @last_change && (fc - @last_change) >= DEBOUNCE_FRAMES
      stale     = @dirty_since && (fc - @dirty_since) >= STALENESS_FRAMES
      flush_primitives if quiescent || stale
    end

    # Send the coalesced primitive channels as one frame each, then clear.
    def flush_primitives
      c = PEMK.client
      return unless c && c.connected? && dirty?

      # A gated deal in doubt (E3): the money and the items wait for its outcome, so the
      # server's ledger and record still hold the deal when its answer comes back.
      doubt = (PEMK::Shop.holding? rescue false)
      # M3: the money waits for the verdicts of the prizes the engine added this session,
      # so the server never judges a frame ahead of its claims.
      held = !doubt && (PEMK::PrizeClaim.holding? rescue false)
      # B2: the badges wait for the claim and the record of the win that gives them.
      bheld = !doubt && badges_waiting?
      unless doubt
        @econ.each do |field, value|
          next if held && field == :money
          next if bheld && field == :badges

          seq = (@seq[:economy] += 1)
          c.send_message({ :type => :econ, :field => field, :value => value, :seq => seq })
          @econ_sent[field] = [seq, value]
        end
      end
      # Switches/variables/self-switches: one whole-state read HERE (game thread),
      # sent as an absolute snapshot and hash-gated so an unchanged story costs
      # nothing. Detection shadow — the server records it and flags a rewind.
      if (PEMK::Flags.active? rescue false)
        # Deltas FIRST: the server must fold every intercepted write into its mirror
        # BEFORE the absolute snapshot arrives, or the trust-gate comparison would
        # judge a mirror that is legitimately one flush behind.
        d = (PEMK::Flags::Delta.drain rescue nil)
        if d
          c.send_message({ :type => :flag_delta, :switches => d[:switches],
                           :variables => d[:variables], :self_switches => d[:self_switches],
                           :overflow => d[:overflow] })
        end
        snap = (PEMK::Flags.projection rescue nil)
        if snap
          if snap.hash != @flag_last
            c.send_message({ :type => :flags, :switches => snap[:switches],
                             :variables => snap[:variables], :self_switches => snap[:self_switches],
                             :event_times => snap[:event_times],
                             :seq => (@seq[:flags] += 1) })
            @flag_last = snap.hash
          end
          @flag_dirty = false   # clear only once the state was actually readable
        end
      end
      # Bag: one whole-bag read HERE (game thread), sent as an absolute snapshot.
      # An empty bag ({}) is a valid send; only a nil (no $bag yet) keeps the flag.
      # Step 6: the server settles gift grants with the bag snapshots that follow them,
      # so none leaves while a gift is between its request and its :gift_applied, and
      # the owed gifts reach a new connection first.
      # Nor while an item moves between two stores in two steps (ItemTransit): the bag
      # would show it while the Pokemon still holds it.
      if @inv_dirty && !doubt && !(PEMK::GiftClaim.holding? rescue false) && !(PEMK::Inventory.atomic? rescue false)
        (PEMK::GiftClaim.before_bag_flush rescue nil)
        bag = PEMK::Inventory.full_bag
        if bag
          # Item authority E0: the PC, the mailbox and held items ride the same snapshot,
          # so the server records them together. Sent only when something changed.
          stores = (PEMK::Inventory.stores rescue nil)
          snap = [bag, stores].hash
          if snap != @inv_last
            msg = { :type => :inv, :bag => bag, :seq => (@seq[:inv] += 1) }
            msg[:stores] = stores if stores
            fixed = (PEMK::ItemCorrect.take_applied rescue nil)   # E4: the correction this shows applied
            msg[:corrected] = fixed if fixed
            c.send_message(msg)
            @inv_last = snap
          end
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
          # M4 Layer D D1: the full-stat team for server legality audit, on change only.
          team = (PEMK::TeamReport.build rescue nil)
          if team && team.hash != @team_last
            c.send_message({ :type => :team_check, :team => team, :seq => (@seq[:team] += 1) })
            @team_last = team.hash
          end
        end
        @mon_dirty = more ? true : false   # stay dirty while mints remain pending
      end
      unless doubt
        kept = {}
        kept[:money] = @econ[:money] if held && @econ.key?(:money)
        kept[:badges] = @econ[:badges] if bheld && @econ.key?(:badges)
        @econ = kept
      end
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
      if @save_wait
        return :throttled if !force && now < @save_wait   # a save not written: sent again at its time
      elsif !force && (now - @blob_at) < BLOB_MIN_INTERVAL
        return :throttled
      end

      raw = File.binread(save_file)
      h = raw.hash
      return :unchanged if h == @blob_hash   # unchanged since the last push -> skip

      # The blob's durability watermark rides along (stamped at serialize time, see
      # mark_blob_watermark): the server promotes progression facts up to it and holds
      # anything newer until the next save.
      msg = { :type => :save, :seq => (@seq[:save] += 1), :flags_seq => @blob_fseq }
      msg[:claims] = @blob_claims if @blob_claims.is_a?(Array)   # P4: the claims this blob carries
      c.send_message(msg, raw)
      @blob_hash = h
      @blob_at = now
      @save_wait = nil
      @save_unacked = { :seq => @seq[:save], :at => now } if @save_ack
      PEMK.log("sync: pushed save blob (#{raw.bytesize}B, seq #{@seq[:save]})")
      :pushed
    rescue => e
      PEMK.log("sync: blob push failed: #{e.class}: #{e.message}")
      :offline
    end

    # The server's word on a pushed save (:save_ok / :save_err, naming its seq). Only the
    # latest save counts: an answer to an older one is overtaken by the newer save's.
    def on_save_reply(msg)
      seq = msg[:seq]
      return unless seq.is_a?(Integer) && seq == @seq[:save]

      if msg[:type] == :save_ok
        @save_unacked = nil
        @save_retry = SAVE_RETRY_FIRST
        return unless @save_failing

        @save_failing = false
        (PEMK::NetStatus.reset_key(:save_failed) rescue nil)
        (PEMK::NetStatus.notify(nil, _INTL("Your progress is saving online again.")) rescue nil)
      elsif msg[:reason] == "too_large"
        @save_unacked = nil   # the same bytes would be refused again
        PEMK.log("sync: save too large for the server (max #{msg[:max]}B)")
        (PEMK::NetStatus.notify(:save_too_large, _INTL("This save is too large for the server: your progress is only kept on this computer.")) rescue nil)
      else
        save_not_written("the server could not write it (#{msg[:reason]})")
      end
    end

    # A save pushed SAVE_ACK_WAIT ago that the server never answered is sent again. With
    # the connection gone, the reconnect sends the save anyway.
    def watch_save_ack
      return unless @save_unacked

      c = PEMK.client
      return (@save_unacked = nil) unless c && c.connected?

      save_not_written("no answer in #{SAVE_ACK_WAIT.to_i}s") if mono - @save_unacked[:at] > SAVE_ACK_WAIT
    end

    def save_not_written(why)
      PEMK.log("sync: save not written (#{why}) -> sent again in #{@save_retry.to_i}s")
      @save_unacked = nil
      @blob_hash = nil                     # the same bytes go out again
      @save_wait = mono + @save_retry
      @save_retry = [@save_retry * 2, SAVE_RETRY_MAX].min
      @save_failing = true
      (PEMK::Checkpoint.push_later rescue nil)
      (PEMK::NetStatus.notify(:save_failed, _INTL("Your progress could not be saved to the server. Trying again...")) rescue nil)
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
