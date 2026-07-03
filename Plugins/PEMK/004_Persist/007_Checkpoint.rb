#===============================================================================
# PEMK :: Checkpoint  (event-driven auto-persistence — the player never saves)
#-------------------------------------------------------------------------------
# MMO semantics: quit anytime, log back in, your progress is there. Triggers
# (map enter, battle end, Pokémon added, badge, PC close, periodic-when-active)
# NEVER save directly — they only arm a pending request. A per-frame executor
# (Checkpoint.tick, driven from Pump.tick which runs inside EVERY blocking loop
# via the Graphics.update alias) fires the checkpoint at the first frame that
# passes a safety gate STRICTLY stronger than vanilla's own save surface:
# vanilla saves mid-interpreter via event command 352 (the serialized
# $game_system.map_interpreter resumes at its index — engine-benign), but a relog
# landing mid-cutscene is terrible UX and message/choice progress ($game_temp) is
# NOT saved, so we refuse while any script runs.
#
# commit() single-sources the load-bearing ordering for BOTH manual and auto
# saves: flush T1 primitives FIRST (the monster sweep assigns mint nonces at
# flush and they must Marshal into the very blob being written), THEN the core
# write via the preserved original Game.save, THEN the blob push. Manual pushes
# force:true (instant); auto pushes force:false so the existing content-hash +
# 30s throttle bounds the wire unconditionally.
#
# Fully silent (no player-facing UI). The Save button keeps working and now
# doubles as "force an immediate full push". OFFLINE (never logged in): inert —
# vanilla save/load semantics preserved exactly.
#===============================================================================
module PEMK
  module Checkpoint
    MIN_INTERVAL     = 20.0    # seconds between auto serializes (trailing coalescing)
    PERIODIC_S       = 120.0   # activity-gated catch-all (story flags, dex, ...)
    FAIL_COOLDOWN    = 60.0    # after a failed write; doubles per consecutive failure
    FAIL_COOLDOWN_MAX = 960.0
    PENDING_WARN_AGE = 300.0   # a request pending this long = a stuck gate; log once

    @pending        = nil      # { :reasons => [..], :since => mono }
    @last_cp        = nil      # last successful checkpoint (nil until first tick)
    @cooldown       = FAIL_COOLDOWN
    @cooldown_until = -1.0e18
    @push_pending   = false
    @push_last_try  = -1.0e18
    @activity       = false
    @running        = false
    @warned_stuck   = false

    module_function

    # --- triggers (flag-only; execution is always deferred to the gated tick) ---
    def request(reason)
      if @pending
        @pending[:reasons] << reason
      else
        @pending = { :reasons => [reason], :since => mono }
        @warned_stuck = false
      end
      @activity = true
    end

    def note_activity
      @activity = true
    end

    # Manual-save accounting, called AFTER the commit with its real outcome.
    # Only a SUCCESSFUL local write clears the pending auto work (a failed manual
    # save must not swallow an armed auto request or bump the periodic clock),
    # and a force push that could not reach the server (:offline — logged_in? is
    # sticky across a socket drop) keeps the retry loop armed so the blob still
    # lands once the connection returns. "Saved!" on screen must mean durable.
    def on_manual_save(ok, push)
      return unless ok

      @pending        = nil
      @last_cp        = mono
      @activity       = false
      @cooldown       = FAIL_COOLDOWN
      @cooldown_until = -1.0e18
      @push_pending   = !(push == :pushed || push == :unchanged)
      @warned_stuck   = false
    end

    # --- the ONE ordered commit (manual + auto) ---------------------------------
    # (1) flush primitives FIRST — mint nonces must Marshal into this very blob;
    # (2) core write via the preserved original (save_count/magic_number/$stats,
    #     Graphics.frame_reset, IOError rescue — zero UI), made ATOMIC: serialize
    #     into a sibling temp file and rename over the target. Vanilla's
    #     truncate-then-Marshal ran only on rare explicit saves; checkpoints run
    #     it every 20-120s, so a kill/raise mid-write would otherwise leave a
    #     truncated Game.rxdata that crashes the NEXT boot before our load alias
    #     can even reach the server blob. File.rename replaces atomically
    #     (MoveFileEx on Windows) — a failed write always leaves the last good file;
    # (3) push the blob. -> [ok, push_status]
    def commit(save_file: SaveData::FILE_PATH, safe: false, force: false)
      (PEMK::Sync.flush_event(:save) rescue nil)
      tmp = save_file + ".ckpt"
      ok = Game.pokemmo_orig_save(tmp, safe: safe)
      if ok
        begin
          File.rename(tmp, save_file)
        rescue StandardError => e
          PEMK.log("checkpoint: atomic rename failed: #{e.class}: #{e.message}")
          ok = false
        end
      end
      if !ok
        begin
          File.delete(tmp) if File.file?(tmp)   # never leave a stale temp behind
        rescue StandardError
          nil
        end
      end
      push = nil
      push = ((PEMK::Sync.push_blob(save_file, force: force) rescue :offline)) if ok
      [ok, push]
    end

    # --- per-frame executor (from Pump.tick; must stay O(1) when idle) ----------
    def tick
      return if @running
      return unless PEMK::Auth.logged_in?   # offline = fully inert (vanilla semantics)

      now = mono
      @last_cp ||= now                       # session baseline (no boot-instant periodic)

      # Deferred blob push: the checkpoint wrote locally but the 30s wire window
      # was closed (or we were offline). Retry at most once per second; a hash
      # match (:unchanged) is success too, or an idle player would retry forever.
      if @push_pending && (now - @push_last_try) >= 1.0
        @push_last_try = now
        st = (PEMK::Sync.push_blob(SaveData::FILE_PATH, force: false) rescue :offline)
        @push_pending = false if st == :pushed || st == :unchanged
      end

      # Activity-gated periodic catch-all (unobserved mutations: switches, dex...).
      request(:periodic) if @pending.nil? && @activity && (now - @last_cp) >= PERIODIC_S

      return unless @pending

      if !@warned_stuck && (now - @pending[:since]) > PENDING_WARN_AGE
        PEMK.log("checkpoint: pending >#{PENDING_WARN_AGE.to_i}s (#{@pending[:reasons].uniq.join(',')}) — gate never opened?")
        @warned_stuck = true
      end
      return if now < @cooldown_until
      return if (now - @last_cp) < MIN_INTERVAL
      return unless safe_frame?

      execute(now)
    end

    # ALL must hold on the executing frame. Verified against core Game_Temp flags;
    # the vanilla pause-menu save trio (save_disabled/Safari/BugContest) included.
    def safe_frame?
      return false unless $player && $game_temp && $scene.is_a?(Scene_Map)
      gt = $game_temp
      return false if gt.in_battle || gt.in_menu || gt.in_storage || gt.message_window_showing
      return false if gt.player_transferring || gt.transition_processing || gt.in_mini_update
      return false if pbMapInterpreterRunning?            # never checkpoint mid-cutscene
      return false if $game_player&.moving? || ($PokemonGlobal&.forced_movement? rescue false)
      return false if $game_system&.save_disabled || (pbInSafari? rescue false) || (pbInBugContest? rescue false)
      # Battle Frontier: pbStart wrote a safe:true recovery snapshot that must stay
      # the LAST save until pbEnd — a mid-challenge checkpoint would overwrite it.
      # ($PokemonGlobal.challenge is lazily allocated; never call pbBattleChallenge here.)
      return false if ($PokemonGlobal&.challenge&.pbInChallenge? rescue false)
      return false if PEMK::BattleSetup.launch_pending?   # a PvP battle is staged this frame
      true
    rescue StandardError
      false
    end

    def execute(now)
      @running = true
      reasons = @pending[:reasons].uniq
      ok = false
      push = nil
      begin
        ok, push = commit(force: false)
      rescue => e
        # Own rescue + cooldown: Pump's rescue alone would retry a throwing
        # Marshal every frame (a 60fps exception storm). Core Game.save only
        # rescues IOError/SystemCallError; anything else lands here.
        PEMK.log("checkpoint: error: #{e.class}: #{e.message}")
        ok = false
      ensure
        @running = false
      end
      if ok
        @pending        = nil
        @last_cp        = now
        @activity       = false
        @cooldown       = FAIL_COOLDOWN
        @cooldown_until = -1.0e18
        @push_pending   = !(push == :pushed || push == :unchanged)
        PEMK.log("checkpoint: saved (#{reasons.join(',')}) push=#{push}")
      else
        @cooldown_until = now + @cooldown
        # Disarm the deferred push: after a failed commit nothing new reached the
        # disk, and the next SUCCESSFUL commit re-arms its own push (content hash
        # covers anything the dropped retry would have sent). The atomic rename
        # already guarantees the on-disk file is the last GOOD save regardless.
        @push_pending = false
        PEMK.log("checkpoint: write failed, retrying in #{@cooldown.to_i}s (pending kept)")
        @cooldown = [@cooldown * 2, FAIL_COOLDOWN_MAX].min
      end
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end

# --- trigger wiring --------------------------------------------------------------
# Battle end: fires while $game_temp.in_battle is STILL true, inside the battle
# fade — and core's :evolve_and_black_out may still evolve/teleport after us.
# Flag-only is mandatory; the executor fires on the first clean overworld frame,
# capturing exp, catches, evolutions and the post-blackout position.
EventHandlers.add(:on_end_battle, :pemk_ckpt_battle,
  proc { |_outcome, _can_lose| PEMK::Checkpoint.request(:battle) })

# Player movement = activity (feeds the periodic catch-all; steps alone don't save).
EventHandlers.add(:on_player_step_taken, :pemk_ckpt_activity,
  proc { PEMK::Checkpoint.note_activity })

# Pokémon added outside battle (gift/starter/trade — catches ride :battle above).
unless defined?(pemk_ckpt_orig_pbAddPokemon)
  alias pemk_ckpt_orig_pbAddPokemon pbAddPokemon
  def pbAddPokemon(pkmn, level = 1, see_form = true)
    ret = pemk_ckpt_orig_pbAddPokemon(pkmn, level, see_form)
    (PEMK::Checkpoint.request(:pokemon) rescue nil) if ret
    ret
  end

  alias pemk_ckpt_orig_pbAddPokemonSilent pbAddPokemonSilent
  def pbAddPokemonSilent(pkmn, level = 1, see_form = true)
    ret = pemk_ckpt_orig_pbAddPokemonSilent(pkmn, level, see_form)
    (PEMK::Checkpoint.request(:pokemon) rescue nil) if ret
    ret
  end

  # PC close: box reorganization is blob-only data; defers past the PC event.
  alias pemk_ckpt_orig_pbTrainerPC pbTrainerPC
  def pbTrainerPC
    ret = pemk_ckpt_orig_pbTrainerPC
    (PEMK::Checkpoint.request(:pc) rescue nil)
    ret
  end

  alias pemk_ckpt_orig_pbPokeCenterPC pbPokeCenterPC
  def pbPokeCenterPC
    ret = pemk_ckpt_orig_pbPokeCenterPC
    (PEMK::Checkpoint.request(:pc) rescue nil)
    ret
  end
end
