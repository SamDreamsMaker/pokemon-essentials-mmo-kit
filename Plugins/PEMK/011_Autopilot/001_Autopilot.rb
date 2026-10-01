#===============================================================================
# PEMK :: Autopilot  (debug-only remote control for automated testing)
#-------------------------------------------------------------------------------
# Lets a test harness or an AI agent drive this game window and read its state
# without touching the mouse, the keyboard or the window focus: commands go through
# the engine's own Input module (002_VirtualInput) and state is read straight from
# the game objects (003_Observe).
#
# OFF unless BOTH hold: a debug launch ($DEBUG) and PEMK_AUTOPILOT=<directory>. A
# player build has neither, and when off nothing below is even hooked.
#
# The channel is two files in that directory, so any language can drive it and no
# port is opened:
#   cmd.txt   one line, "<id> <verb> [args]", written by the driver (via rename)
#   resp.txt  one JSON object {"id": ..., "ok": ...}, written by the game (via rename)
# One command at a time. The game polls cmd.txt once per frame from Graphics.update
# (mkxp-z starves background threads, so there is no listener thread); a command that
# spans frames (press, wait) answers when it is done. tools/autopilot/ap.sh is a
# ready-made driver.
#===============================================================================
module PEMK
  module Autopilot
    CMD_FILE  = "cmd.txt"
    RESP_FILE = "resp.txt"
    MAX_LINE  = 1024
    # Verbs answered even while another command is still running, so a stuck command
    # can always be looked at, and cancelled.
    IMMEDIATE = %w[ping state screenshot verbs keys abort].freeze
    # Seconds a multi-frame command may take before it gives up. Wall-clock, not
    # frames: a window hidden behind others can run far above 60 frames a second.
    JOB_SECONDS = 60.0
    # vsync paces the frames only while the window is on screen; hidden behind other
    # windows mkxp-z spins as fast as it can (thousands of frames a second, measured),
    # which burns a core per test window and makes "a few frames" mean nothing next
    # to the engine's real-time animations. The autopilot paces frames itself.
    FRAME_SECONDS = 1.0 / 60

    @dir      = nil
    @verbs    = {}
    @job      = nil
    @job_id   = nil
    @limit    = JOB_SECONDS
    @deadline = nil
    # Frames are counted here, not read from Graphics.frame_count: loading a save
    # restores that counter to the saved play time, which would fire every pending
    # deadline at once.
    @frames   = 0
    @frame_at = nil
    @undeleted = nil   # a command whose file would not go: it ran, never twice

    module_function

    def active?
      !@dir.nil?
    end

    # Active, and not denied by the server (PEMK::DebugLock): it may drive the game -
    # keys, battles, text entry, item choice. Denied, the game is the player's alone.
    def driving?
      active? && (!defined?(PEMK::DebugLock) || PEMK::DebugLock.autopilot_allowed?)
    end

    # The server denied it (DebugLock, at login): the running command ends, and every
    # setting a command left on goes - held keys, a battle mode, auto-advance, held saves.
    def disarm
      job = @job ? @job_id : nil
      @job = nil
      (VInput.release_all rescue nil)
      ((BattleControl.mode = :keys) rescue nil) if defined?(BattleControl)
      ((Actions.advance = false) rescue nil) if defined?(Actions)
      (Actions.restore_options rescue nil) if defined?(Actions)
      ((SaveHold.on = false) rescue nil) if defined?(SaveHold) && SaveHold.on
      PEMK.log("autopilot: disarmed - the server denies debug mode; it only reads now")
      # last: a channel that cannot be written to leaves the game the player's anyway
      (respond(job, "ok" => false, "error" => "locked by the server (PEMK_CLIENT_DEBUG=deny)") rescue nil) if job
    end

    def dir
      @dir
    end

    # Called once at load. -> true when this window is remote-controlled.
    def boot(env = ENV, debug = $DEBUG)
      raw = env["PEMK_AUTOPILOT"].to_s.strip
      return false if raw.empty?

      unless debug
        PEMK.log("autopilot: PEMK_AUTOPILOT is set but this is not a debug launch - ignored")
        return false
      end
      dir = File.expand_path(raw)
      make_dirs(dir)
      @dir = dir
      PEMK.log("autopilot: on, channel #{dir}")
      true
    rescue StandardError => e
      PEMK.log("autopilot: cannot open channel #{raw.inspect}: #{e.class}: #{e.message}")
      false
    end

    # mkdir -p without fileutils, which mkxp-z does not ship.
    def make_dirs(path)
      return if File.directory?(path)

      parent = File.dirname(path)
      make_dirs(parent) unless parent == path
      Dir.mkdir(path)
    end

    # Once per frame, from Graphics.update.
    def tick
      return unless @dir

      pace
      @frames += 1
      step_job if @job

      path = File.join(@dir, CMD_FILE)
      return unless File.file?(path)

      raw = read_command(path)
      # A writer that does not rename its file in (echo > cmd.txt) can be caught
      # between creating it and writing it: read it again on a later frame.
      return if raw.nil? || raw.empty?

      line = raw.force_encoding(Encoding::UTF_8)
      # While a command runs, only the ones that just look (or abort it) cut in; the
      # rest waits its turn in the file.
      return if @job && !IMMEDIATE.include?(line.split(/\s+/, 3)[1].to_s)
      # Its file could not be deleted: it already ran. The next command replaces it.
      return if line == @undeleted

      begin
        File.delete(path)
        @undeleted = nil
      rescue SystemCallError
        @undeleted = line
      end
      run(line)
    rescue StandardError => e
      PEMK.log("autopilot: tick error #{e.class}: #{e.message}")
    end

    # The driver renames its file in; from WSL, the game can open it at the moment
    # the rename lands and be refused. Read it again on a later frame.
    def read_command(path)
      File.binread(path, MAX_LINE)
    rescue Errno::EACCES, Errno::ENOENT
      nil
    end

    # Verbs register themselves here (this file, 004_Battle, 005_World...), so each
    # file owns its commands. The handler gets the command id and the rest of the line.
    def verb(name, &handler)
      @verbs[name] = handler
    end

    def verbs
      @verbs.keys.sort
    end

    # What the autopilot still does where the server denies debug mode: look and wait.
    READ_ONLY = %w[ping verbs keys state screenshot events event_pages grass wait wait_until abort
                   get_switch get_var get_selfswitch get_item get_pc get_held].freeze

    def run(line)
      id, name, rest = line.strip.split(/\s+/, 3)
      return if id.nil? || id.empty?

      handler = @verbs[name.to_s]
      return respond(id, "ok" => false, "error" => "unknown verb #{name.inspect}", "verbs" => verbs) unless handler
      unless READ_ONLY.include?(name.to_s) || !defined?(PEMK::DebugLock) || PEMK::DebugLock.autopilot_allowed?
        return respond(id, "ok" => false, "error" => "locked by the server (PEMK_CLIENT_DEBUG=deny)")
      end

      handler.call(id, rest.to_s)
    rescue StandardError => e
      respond(id, "ok" => false, "error" => "#{e.class}: #{e.message}")
    end

    # press KEY [steps] - hold KEY for that many Input steps (default 2), then release.
    # Answers once the release has happened and the scene has run one frame on it, so
    # a "state" sent next already sees the effect.
    def cmd_press(id, rest)
      name, count = rest.to_s.split
      key = VInput.key(name)
      return respond(id, "ok" => false, "error" => "unknown key #{name.inspect}") unless key

      VInput.hold(key, count ? count.to_i.clamp(1, 600) : 2)
      settled = nil
      start_job(id) do
        next false if VInput.down?(key)

        settled ||= frame
        next false if frame == settled

        respond(id, "ok" => true, "frame" => frame)
      end
    end

    # hold KEY - keep KEY down until "release KEY" (walking, fast-forwarding text).
    def cmd_hold(id, rest)
      key = VInput.key(rest.to_s.strip)
      return respond(id, "ok" => false, "error" => "unknown key #{rest.to_s.strip.inspect}") unless key

      VInput.hold(key, nil)
      respond(id, "ok" => true, "frame" => frame)
    end

    # release KEY | release all
    def cmd_release(id, rest)
      name = rest.to_s.strip
      if name.casecmp?("all")
        VInput.release_all
      else
        key = VInput.key(name)
        return respond(id, "ok" => false, "error" => "unknown key #{name.inspect}") unless key

        VInput.release(key)
      end
      respond(id, "ok" => true, "frame" => frame)
    end

    # wait FRAMES | wait 2s | wait 500ms. Frames are what the engine counts; seconds
    # are what its animations and message timers run on.
    def cmd_wait(id, rest)
      arg = rest.strip
      if (m = arg.match(/\A(\d+(?:\.\d+)?)(ms|s)\z/))
        secs = m[2] == "ms" ? m[1].to_f / 1000 : m[1].to_f
        stop = now + secs.clamp(0.0, JOB_SECONDS - 1)
        start_job(id) do
          next false if now < stop

          respond(id, "ok" => true, "frame" => frame)
        end
      else
        count  = arg.to_i.clamp(1, 100_000)
        target = frame + count
        start_job(id, [JOB_SECONDS, count / 10.0].max) do
          next false if frame < target

          respond(id, "ok" => true, "frame" => frame)
        end
      end
    end

    # screenshot [PATH] - PNG of the current frame; a relative PATH lands in the channel
    # directory, and no PATH picks shot-<frame>.png there.
    def cmd_screenshot(id, rest)
      path = rest.to_s.strip
      path = "shot-#{frame}.png" if path.empty?
      path = File.expand_path(path, @dir)
      Graphics.screenshot(path)
      respond(id, "ok" => true, "path" => path, "frame" => frame)
    end

    # A multi-frame command: the block runs once per frame until it returns true, or
    # gives up after that many seconds.
    def start_job(id, seconds = JOB_SECONDS, &block)
      @job      = block
      @job_id   = id
      @limit    = seconds
      @deadline = now + seconds
    end

    def step_job
      if now > @deadline
        VInput.release_all
        respond(@job_id, "ok" => false, "error" => "timeout after #{@limit}s")
        @job = nil
      elsif @job.call
        @job = nil
      end
    rescue StandardError => e
      @job = nil
      respond(@job_id, "ok" => false, "error" => "#{e.class}: #{e.message}")
    end

    # abort - cancel the running command: it answers "aborted", held keys come up.
    def cmd_abort(id)
      stopped = @job_id if @job
      if @job
        @job = nil
        VInput.release_all
        respond(stopped, "ok" => false, "error" => "aborted")
      end
      respond(id, "ok" => true, "aborted" => stopped)
    end

    def respond(id, payload)
      body = PEMK::WorldExport.jval({ "id" => id }.merge(payload))
      tmp  = File.join(@dir, ".resp.tmp")
      File.open(tmp, "wb") { |f| f.write(body) }
      File.rename(tmp, File.join(@dir, RESP_FILE))
      true
    end

    def frame
      @frames
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Sleep off what is left of the frame (sleep yields the GVL, as the login loop
    # relies on). On screen, vsync already took the time and this sleeps nothing.
    def pace
      t = now
      if @frame_at
        spare = FRAME_SECONDS - (t - @frame_at)
        sleep(spare) if spare > 0.001
      end
      @frame_at = now
    end

    verb("ping")       { |id, _| respond(id, "ok" => true, "frame" => frame) }
    verb("verbs")      { |id, _| respond(id, "ok" => true, "verbs" => verbs) }
    verb("keys")       { |id, _| respond(id, "ok" => true, "keys" => VInput::NAMES) }
    verb("state")      { |id, _| respond(id, { "ok" => true }.merge(Observe.snapshot)) }
    verb("press")      { |id, rest| cmd_press(id, rest) }
    verb("hold")       { |id, rest| cmd_hold(id, rest) }
    verb("release")    { |id, rest| cmd_release(id, rest) }
    verb("wait")       { |id, rest| cmd_wait(id, rest) }
    verb("screenshot") { |id, rest| cmd_screenshot(id, rest) }
    verb("abort")      { |id, _| cmd_abort(id) }
  end
end

# The per-frame poll. Hooked only when this window is remote-controlled.
if PEMK::Autopilot.boot
  module Graphics
    class << self
      unless method_defined?(:pemk_ap_orig_update)
        alias_method :pemk_ap_orig_update, :update
        def update(*args)
          pemk_ap_orig_update(*args)
          PEMK::Autopilot.tick
        end
      end
    end
  end
end
