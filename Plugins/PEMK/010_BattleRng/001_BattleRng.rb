#===============================================================================
# PEMK :: BattleRng  (client side — M4 Layer D D7 part 1: deterministic battles)
#-------------------------------------------------------------------------------
# The engine tier's client seam. Two jobs, both scoped to SINGLE-FOE WILD battles
# and both dormant unless the server advertises PEMK_BATTLE_ENFORCE_RNG:
#
#   shadow — RECORD: the battle runs on vanilla RNG, but every pbRandom /
#     pbAIRandom draw is tapped (bound+value packed logs, per-stream counts +
#     FNV-1a64 fingerprints), every round's choices (@choices) and mega state
#     (@megaEvolution) are snapshotted at the END of pbCommandPhase, forced
#     switches and the outcome are captured, and the whole primitive-encoded
#     record is sent fire-and-forget as :battle_record. This corpus is what
#     part 2's headless replay validates the harness against.
#
#   on — DERIVE: the battle's RNG comes from the server's 63-bit PCG32 seed
#     (born with the D2 encounter mint, rides :encounter_grant). Three domain-
#     separated streams: battle (pbRandom), ai (pbAIRandom), run (pbRun's flee
#     rolls — routed via a context flag because replay re-registers choices and
#     never re-runs the AI, but DOES re-run the flee roll). Rolls become
#     derived-not-trusted; a fabricated favorable roll can no longer be claimed.
#
# The MODE IS LATCHED AT ARM TIME (battle start): a mid-battle relogin adopting
# a different server mode never flips streams mid-stream. Any fault anywhere
# falls back to vanilla behavior (the alias returns super's value untouched).
# Zero engine-file edits: Battle / Battle::AI are reopened, methods aliased.
#
# INSTRUMENTATION, not enforcement: nothing here (or server-side) rejects a
# battle. Rejection is D8's own flag, per the operator contract.
#
# Trainer proof (docs/TRAINER-PROOF-DESIGN.md): a trainer battle runs on its placement's
# seed, and its record is what its prize is paid on (P4) - kept in the save until the
# server acknowledges it.
#===============================================================================
class PokemonGlobalMetadata
  attr_accessor :pemk_battle_records   # [[rec_nonce, env, body], ...] not yet acknowledged
end

module PEMK
  module BattleRng
    MAX_ROUNDS = 200    # rounds snapshotted per record (beyond -> truncated flag)
    MAX_DRAWS  = 4096   # per-stream packed-log cap (counts/fps keep counting)
    TRAINER_SEED_WAIT = 2.0   # seconds a trainer battle waits for its seed at the start
    TRAINER_SEED_WAIT_PROOF = 6.0   # ... when its prize is paid on its replay: a battle
                                    # without its seed would have its prize refused (P4)
    RECORDS_KEPT     = 4            # trainer battle records kept until acknowledged (P4)
    RECORDS_KEPT_MAX = 128 * 1024   # ... and their bytes at most: they ride in the save
    RECORD_RESEND    = 30.0         # seconds before an unacknowledged record goes out again
    BADGE_SEED_WAIT  = 30.0         # B2: seconds a battle whose win gives a badge waits for its seed
                                    # (a win with no seed proves no badge); while online only

    @mode      = :off   # server-advertised mode (adopted at login/relogin)
    @pending   = nil    # {seed:, pid:} from the last :encounter_grant build
    @engine_fp = nil    # lazy cohort fingerprint (survives for the session)
    @trainer_seed_ok = false   # the server seeds trainer battles (login flag, P2)
    @trainer_asks    = {}      # nonce => nil (asked) | seed | :denied
    @trainer_nonce   = 0
    @record_ack  = false   # the server acknowledges trainer battle records (login flag, P4)
    @proof_on    = false   # a trainer prize is paid on its battle's replay (login flag, P4)
    @record_sent = {}      # rec_nonce => when this connection last sent it
    @rec_rng     = nil
    @badge_battles = []    # B2: [type, name, version, map, event] whose win gives a badge (login)
    @core_single   = false # B2: TrainerBattle.start_core runs a battle against one trainer

    module_function

    def reset
      @mode    = :off
      @pending = nil
      @trainer_seed_ok = false
      @trainer_asks    = {}
      @badge_battles = []
      @record_ack  = false
      @proof_on    = false
      @record_sent = {}   # every kept record goes out again on the new connection
    end

    def adopt_badge_battles(list)
      @badge_battles = Array(list).select { |t| t.is_a?(Array) && t.length == 5 }
    end

    # B2: a trainer battle's record the server has not acknowledged yet - the badges wait
    # for it.
    def records_unacked?
      @record_ack && !kept_records.empty?
    end

    def adopt_trainer_seed(v)
      @trainer_seed_ok = v == true
    end

    def adopt_record_ack(v)
      @record_ack = v == true
    end

    def adopt_trainer_proof(v)
      @proof_on = v.to_s == "on"
    end

    # Trainer proof P2 (docs/TRAINER-PROOF-DESIGN.md), from :on_trainer_load: a trainer is
    # about to be fought - ask its placement's seed now, so the answer is back by the
    # battle's start (the transition hides the round trip). Only for a battle the recorder
    # arms (P4): with no seed asked, a battle it cannot record is not one that dropped its
    # seed.
    def ask_trainer_seed(trainer)
      return unless @mode == :on && @trainer_seed_ok && online?

      key = trainer.respond_to?(:pemk_key) ? trainer.pemk_key : nil
      ev  = trainer.respond_to?(:pemk_event) ? trainer.pemk_event : nil
      return unless key && ev

      # B2: while the server judges the badges, a battle whose win gives one is fought alone
      # - a partner's battle gets no seed, and no replay could prove the win. Only the battle
      # TrainerBattle.start_core sets up against that trainer alone: its rules clear after it.
      badge = @badge_battles.include?(key + ev)
      ($game_temp.battle_rules["noPartner"] = true rescue nil) if badge && @core_single && single_size?
      return unless single_rules?

      nonce = (@trainer_nonce += 1)
      @trainer_asks[nonce] = nil
      trainer.instance_variable_set(:@pemk_seed_nonce, nonce)
      trainer.instance_variable_set(:@pemk_seed_badge, badge)   # ... and waits for its seed longer
      (PEMK::Presence.emit_now(:pos) rescue nil)   # asked where the server last saw the player
      PEMK.send_message(:type => :trainer_battle_req, :nonce => nonce, :trainers => [key + ev])
    rescue StandardError => e
      PEMK.log("battlerng: trainer seed ask error #{e.class}: #{e.message}")
    end

    # B2: TrainerBattle.start_core, around the battle it sets up - against one trainer? Two
    # (one waited for the other) make no badge's battle, and a trainer loaded anywhere else
    # (a partner registered, the debug menu) is fought in no battle yet.
    def core_begin(args)
      @core_single = foe_count(args) == 1
    end

    def core_end
      @core_single = false
    end

    # The trainers TrainerBattle.generate_foes reads from +args+, by its own parse: a
    # trainer object or [type, name, version], or type, name and an optional version.
    def foe_count(args)
      n = 0
      type = name = nil
      args.each_with_index do |arg, i|
        if arg.is_a?(Array) || (defined?(NPCTrainer) && arg.is_a?(NPCTrainer))
          n += 1
        elsif name                        # its version
          n += 1
          type = name = nil
        elsif type                        # its name: a version follows, or not
          if args[i + 1].is_a?(Integer)
            name = arg
          else
            n += 1
            type = nil
          end
        else
          type = arg
        end
      end
      n
    end

    # The battle about to start is a single one, with no partner at the player's side -
    # the rules its event set, as TrainerBattle reads them (a partner joins when it can).
    def single_rules?
      return false unless single_size?

      rules = ($game_temp.battle_rules rescue nil) || {}
      partner = ($PokemonGlobal.partner rescue nil)
      !partner || rules["noPartner"] ? true : false
    end

    # No size rule sizes the battle other than single (a tag battle stays one).
    def single_size?
      rules = ($game_temp.battle_rules rescue nil) || {}
      size = rules["size"].to_s.downcase
      size.empty? || size == "single" || size == "1v1"
    end

    # Dispatch: :trainer_battle_seed / :trainer_battle_deny, by nonce.
    def on_trainer_seed(msg)
      n = msg[:nonce]
      return unless @trainer_asks.key?(n)

      seed = msg[:seed]
      @trainer_asks[n] = msg[:type] == :trainer_battle_seed && seed.is_a?(Integer) && seed.positive? ? seed : :denied
    end

    # -> the seed asked for +trainer+, waiting up to TRAINER_SEED_WAIT for it; nil if none
    # (denied, late, never asked: the battle is then recorded unseeded).
    def trainer_seed(trainer)
      n = trainer.instance_variable_get(:@pemk_seed_nonce)
      return nil unless n && @trainer_asks.key?(n)

      badge = trainer.instance_variable_get(:@pemk_seed_badge)
      deadline = mono + (badge ? BADGE_SEED_WAIT : (@proof_on ? TRAINER_SEED_WAIT_PROOF : TRAINER_SEED_WAIT))
      while @trainer_asks[n].nil? && mono < deadline && online?
        Graphics.update
        Input.update
      end
      seed = @trainer_asks.delete(n)
      PEMK.log("battlerng: trainer battle #{seed.is_a?(Integer) ? 'seeded' : "unseeded (#{seed.inspect})"}")
      seed.is_a?(Integer) ? seed : nil
    rescue StandardError
      nil
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end

    # --- trainer battle records, kept until the server has them (P4) ---------------

    # A trainer battle's record: its prize is paid on its replay, so it waits in the save
    # until the server acknowledges it (the oldest go past RECORDS_KEPT or
    # RECORDS_KEPT_MAX). Names it by a nonce the server knows a copy by. The battle's
    # session decides, as it was armed (Session#keep). -> kept?
    def keep_record(env, body)
      return false unless body.is_a?(String)

      nonce = (@rec_rng ||= Random.new).rand(1...(1 << 62))
      env[:rec_nonce] = nonce
      list = kept_records
      list << [nonce, env, body]
      list.shift while list.length > RECORDS_KEPT || (list.length > 1 && list.sum { |e| e[2].bytesize } > RECORDS_KEPT_MAX)
      true
    rescue StandardError => e
      PEMK.log("battlerng: keep record error #{e.class}: #{e.message}")
      false
    end

    def note_record_sent(nonce)
      @record_sent[nonce] = mono
    end

    # Dispatch: :battle_record_ack - the server has it.
    def on_record_ack(msg)
      n = msg[:rec_nonce]
      return unless n.is_a?(Integer)

      if kept_records.reject! { |e| e[0] == n }
        PEMK.log("battlerng: record #{n} acknowledged")
        (PEMK::Sync.remark_badges rescue nil)   # B2: the badges again, the record in
      end
      @record_sent.delete(n)
    end

    # Per frame, and before a new connection's claims: a kept record this connection has
    # not sent, or sent long ago, goes out.
    def send_records
      return unless @record_ack && online?

      list = kept_records
      return if list.empty?

      now = mono
      list.each do |nonce, env, body|
        next if now - (@record_sent[nonce] || -1.0e18) < RECORD_RESEND

        @record_sent[nonce] = now if PEMK.send_message(env, body)
      end
    rescue StandardError => e
      PEMK.log("battlerng: record resend error #{e.class}: #{e.message}")
    end

    def kept_records
      g = $PokemonGlobal
      return [] unless g && g.respond_to?(:pemk_battle_records)

      list = g.pemk_battle_records
      list = g.pemk_battle_records = [] unless list.is_a?(Array)
      list.select! { |e| e.is_a?(Array) && e.length == 3 && e[0].is_a?(Integer) && e[1].is_a?(Hash) && e[2].is_a?(String) }
      list
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end

    def online?
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # From Encounter#build_from_grant: the seed born with this mint (nil-safe).
    def note_grant(seed, pid)
      @pending = { :seed => seed, :pid => pid } if seed.is_a?(Integer) && seed.positive?
    rescue StandardError
      nil
    end

    # ARMING — from the pbStartBattle alias. Shadow arms ANY single-foe wild
    # battle (mint or not: the broad harness-validation corpus); `on` arms ONLY
    # when the foe is the server-minted mon the pending seed was born with.
    # The session latches mode+seed: later adopt_mode never touches a live battle.
    def arm_for(battle)
      return nil if @mode == :off || !online?
      return arm_trainer(battle) if (battle.trainerBattle? rescue false)
      return nil unless battle.wildBattle?
      # SafariBattle overrides pbRandom itself (001_SafariBattle.rb:295) — its rolls
      # would bypass the tap entirely, yielding an armed-but-empty record (and in `on`,
      # a battle that silently never drew from the seed). Out of D7 part 1's scope.
      return nil if defined?(SafariBattle) && battle.is_a?(SafariBattle)

      foes = (battle.pbParty(1) rescue nil)
      return nil unless foes && foes.length == 1 && foes[0]

      pending = @pending
      match = pending && foes[0].personalID == pending[:pid]
      # consume the seed only when ITS battle arms — an intervening non-minted wild
      # (roamer, scaling map) must not eat it; a stale pending is superseded by the
      # next grant and cleared on disconnect.
      @pending = nil if match
      bound = match ? pending[:seed] : nil
      if @mode == :on
        return nil unless bound   # unminted/unmatched wild -> vanilla (fail-open)

        Session.new(:on, bound)
      else
        Session.new(:shadow, bound)
      end
    rescue StandardError => e
      PEMK.log("battlerng: arm error #{e.class}: #{e.message}")
      nil
    end

    # Trainer battles (docs/TRAINER-PROOF-DESIGN.md): a single battle against one trainer
    # is recorded, so the harness can rebuild the trainer's team and re-run its AI against
    # what this client did. Under `on` it runs on its placement's seed (P2); without one
    # (denied, late) it is recorded unseeded, as in shadow.
    def arm_trainer(battle)
      return nil unless @mode == :shadow || @mode == :on

      foes = Array(battle.opponent)
      return nil unless foes.length == 1 && Array(battle.player).length == 1
      return nil unless (battle.pbSideSize(0) == 1 && battle.pbSideSize(1) == 1 rescue false)

      seed = @mode == :on ? trainer_seed(foes[0]) : nil
      s = Session.new(seed ? :on : :shadow, seed)
      s.trainers = foes.map { |t| t.respond_to?(:pemk_key) && t.pemk_key ? Array(t.pemk_key)[0, 3].map { |v| v.is_a?(Symbol) ? v.to_s : v } : nil }
      s.keep = @record_ack   # latched: a link lost mid-battle must not lose its record (P4)
      s.watch_forgets(battle)
      s
    rescue StandardError => e
      PEMK.log("battlerng: trainer arm error #{e.class}: #{e.message}")
      nil
    end

    # Cohort fingerprint: FNV-1a64 over the battle-relevant file inventory
    # ([relpath, bytesize] sorted — cheap, no content hashing) + versions. Good
    # enough to segment corpus records by engine build; documented as inventory-
    # level (a same-size content edit evades it — part 3 can tighten).
    def engine_fp
      @engine_fp ||= begin
        h = Session::FNV_OFFSET
        inventory = []
        ["Data/Scripts/011_Battle/**/*.rb", "Data/Scripts/014_Pokemon/**/*.rb",
         "Data/*.dat", "Plugins/PEMK/**/*.rb"].each do |pat|
          Dir.glob(pat).sort.each do |f|
            inventory << "#{f}:#{(File.size(f) rescue 0)}"
          end
        end
        inventory << "essentials:#{(Essentials::VERSION rescue '?')}"
        inventory.each do |s|
          s.each_byte { |b| h = ((h ^ b) * Session::FNV_PRIME) & Session::M64 }
        end
        format("%016x", h)
      rescue StandardError
        "unknown"
      end
    end

    #===========================================================================
    # One armed battle's capture state. All writes are rescue-guarded at the
    # call sites; a session can never take the battle down.
    #===========================================================================
    class Session
      FNV_OFFSET = 0xcbf29ce484222325
      FNV_PRIME  = 0x100000001b3
      M64        = (1 << 64) - 1

      attr_reader :mode, :seed
      attr_accessor :run_context, :trainers, :keep   # keep: its record waits in the save until acknowledged (P4)

      def initialize(mode, seed)
        @mode        = mode
        @seed        = seed
        @streams     = { :b => new_stream, :a => new_stream, :r => new_stream }
        @prngs       = nil
        if mode == :on
          @prngs = { :b => PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE),
                     :a => PEMK::Prng.new(seed, PEMK::Prng::STREAM_AI),
                     :r => PEMK::Prng.new(seed, PEMK::Prng::STREAM_RUN) }
        end
        @rounds      = []
        @switches    = []
        @runs        = []
        @init        = nil
        @outcome     = nil
        @truncated   = false
        @desynced    = false
        @run_context = false
        @sent        = false
        @trainers    = nil   # a trainer battle: [[type, name, version]], nil = wild
        @map         = ($game_map.map_id rescue nil)   # a level-up's happiness reads it
        @confirms    = []    # every yes/no the player answered (switch, forget a move...)
        @forgets     = []    # the move slot given up for a new move (-1: none)
      end

      # The player's answers the battle asks for, in order: the replay gives them back.
      def note_confirm(ret)
        @confirms << (ret ? true : false) if @confirms.length < MAX_ROUNDS * 4
      end

      # A new move to learn asks which move to forget, on the scene: wrap THIS battle's
      # scene so the choice is recorded (the replay's scene gives it back).
      def watch_forgets(battle)
        scene = battle.scene
        session = self
        orig = scene.method(:pbForgetMove)
        scene.define_singleton_method(:pbForgetMove) do |*args|
          ret = orig.call(*args)
          (session.note_forget(ret) rescue nil)
          ret
        end
      rescue StandardError
        nil
      end

      def note_forget(ret)
        @forgets << (ret.is_a?(Integer) ? ret : -1) if @forgets.length < MAX_ROUNDS
      end

      def outcome?; !@outcome.nil?; end

      # --- the draw path ------------------------------------------------------
      # shadow: +vanilla+ already holds super's value -> tap it. on: DERIVE the
      # value from the seeded stream (vanilla is nil, never drawn). Non-positive /
      # non-Integer / beyond-2^32 bounds exist in the engine's rand mirror — those
      # fall back to vanilla and mark the record desynced (visible, never fatal).
      # INVARIANT the server walk RELIES on: a fallback draw RETURNS before the
      # logging below — fallback values must never enter the stream logs, or an
      # honest desync would fail the seed walk and false-flag the player.
      def draw(kind, bound, vanilla)
        kind = :r if kind == :a && @run_context
        s = @streams[kind]
        if @mode == :on
          unless bound.is_a?(Integer) && bound.positive? && bound <= (1 << 32)
            @desynced = true      # > 2^32 would also infinite-loop rand_below
            return vanilla.call
          end
          value = @prngs[kind].rand_below(bound)
        else
          value = vanilla.call
        end
        s[:n] += 1
        v32 = value.to_i & 0xFFFFFFFF
        b32 = bound.is_a?(Integer) ? bound & 0xFFFFFFFF : 0
        s[:fp] = fold(fold(s[:fp], b32), v32)
        if s[:n] <= MAX_DRAWS
          s[:log] << [b32, v32].pack("NN")
        else
          @truncated = true
        end
        value
      end

      # --- battle-lifecycle snapshots ----------------------------------------
      def snapshot_init(battle)
        @init ||= {
          :player => (battle.pbParty(0) || []).map { |p| p && mon_frame(p) },
          :foe    => (battle.pbParty(1) || []).map { |p| p && mon_frame(p) },
          # a Pokemon from another trainer obeys up to a level the badges set: the replay
          # needs both to roll its disobedience as the game did (trainer proof P4)
          :badges => (battle.pbPlayer.badge_count rescue nil)
        }
        @settings ||= battle_settings(battle) if @trainers
      end

      # What the battle was set to, that its mechanics read: the trainers' bag, the
      # switch style, weather, terrain, environment, whether it can be lost.
      def battle_settings(battle)
        sym = ->(v) { v.nil? ? nil : v.to_s }
        { :items       => Array(battle.items).map { |bag| Array(bag).map { |i| sym.(i) } },
          :switch      => (battle.switchStyle ? true : false),
          :weather     => sym.(battle.field.defaultWeather),   # Battle has only the setters
          :terrain     => sym.(battle.field.defaultTerrain),
          :environment => sym.(battle.environment),
          :can_lose    => (battle.canLose ? true : false),
          :money       => (battle.moneyGain ? true : false) }
      rescue StandardError
        nil
      end

      # End of pbCommandPhase: @choices is fully resolved (registration toggles
      # settled) and @megaEvolution holds the round's mega state — snapshotting
      # HERE is what makes the capture robust (aliasing the 6 register methods
      # misses toggles; this can't). Choice slots are ACT-DEPENDENT (:UseMove
      # [act, idx, MoveObj, target]; :UseItem [act, itemSym, idxTarget, idxMove];
      # :SwitchOut [act, idxParty, ...]) — encode each slot by TYPE so every
      # shape survives (a positional type filter silently dropped the item id of
      # every thrown ball — review-caught).
      def snapshot_round(battle)
        if @rounds.length >= MAX_ROUNDS
          @truncated = true
          return
        end
        choices = (battle.instance_variable_get(:@choices) || []).map do |c|
          c.is_a?(Array) ? [prim(c[0]), prim(c[1]), prim(c[2]), prim(c[3])] : nil
        end
        mega = deep_ints(battle.instance_variable_get(:@megaEvolution))
        @rounds << { :c => choices, :m => mega }
      end

      def snapshot_switch(idx, ret)
        @switches << [idx, ret.is_a?(Integer) ? ret : -1] if @switches.length < MAX_ROUNDS * 4
      end

      # Each pbRun invocation is a PLAYER INPUT replay must know about: the wild
      # end-of-round "Use next Pokémon?" -> "No" path calls pbRun(idx, true), and
      # "Yes -> switch" vs "No -> failed flee -> switch" differ only by this event
      # (review-caught). ret pins the rate>=256 zero-draw short-circuit too.
      def note_run(idx, during, ret)
        @runs << [idx, during ? 1 : 0, ret.is_a?(Integer) ? ret : -99] if @runs.length < MAX_ROUNDS * 4
      end

      # At pbEndOfBattle ENTRY: @decision is set, but the post-battle mutations
      # (Pokérus spread, form resets, held-item restore) have NOT run — the
      # digest must exclude them or replay could never match.
      def snapshot_outcome(battle)
        @outcome = {
          :decision => (battle.decision rescue 0),
          :turns    => (battle.turnCount rescue -1),
          :player   => (battle.pbParty(0) || []).map { |p| p && end_state(p) },
          :foe      => (battle.pbParty(1) || []).map { |p| p && end_state(p) }
        }
      rescue StandardError
        @outcome ||= { :decision => 0, :turns => -1, :player => [], :foe => [] }
      end

      # --- finalize ----------------------------------------------------------
      def finalize_and_send
        return if @sent

        @sent = true
        body = PEMK::MessageCodec.encode_primitive(record_hash)
        env = { :type => :battle_record, :mode => @mode.to_s, :engine_fp => PEMK::BattleRng.engine_fp,
                :outcome => (@outcome && @outcome[:decision]) || 0,
                :rounds => @rounds.length,
                :draws_battle => @streams[:b][:n], :draws_ai => @streams[:a][:n],
                :draws_run => @streams[:r][:n],
                :fp_battle => hex(@streams[:b][:fp]), :fp_ai => hex(@streams[:a][:fp]),
                :fp_run => hex(@streams[:r][:fp]),
                :truncated => @truncated, :desynced => @desynced }
        env[:battle_seed] = @seed if @seed
        kept = @trainers && @keep ? PEMK::BattleRng.keep_record(env, body) : false   # P4: until the server has it
        sent = PEMK.send_message(env, body)
        PEMK::BattleRng.note_record_sent(env[:rec_nonce]) if sent && kept
        PEMK.log("battlerng: #{sent ? 'sent' : 'DROPPED (offline)'} #{@mode} record " \
                 "(#{@rounds.length}r, #{@streams[:b][:n]}/#{@streams[:a][:n]}/#{@streams[:r][:n]} draws" \
                 "#{@truncated ? ', truncated' : ''}#{@desynced ? ', DESYNCED' : ''})")
      rescue StandardError => e
        PEMK.log("battlerng: send failed #{e.class}: #{e.message}")
      end

      private

      def new_stream; { :n => 0, :fp => FNV_OFFSET, :log => +"".b }; end

      def fold(h, v32)
        [v32].pack("N").each_byte { |b| h = ((h ^ b) * FNV_PRIME) & M64 }
        h
      end

      def hex(h); format("%016x", h); end

      # Slot encoder by TYPE: Integers/booleans/nil pass, Symbols stringify, and
      # anything id-bearing (Battle::Move) becomes its id string.
      def prim(v)
        case v
        when Integer, nil, true, false then v
        when Symbol then v.to_s
        else v.respond_to?(:id) ? v.id.to_s : nil
        end
      rescue StandardError
        nil
      end

      def deep_ints(v)
        case v
        when Array then v.map { |e| deep_ints(e) }
        when Integer, true, false, nil then v
        else v.to_s
        end
      end

      # Initial-state frame, TeamReport-shaped (form-resolved species, full set).
      def mon_frame(p)
        tr = PEMK::TeamReport
        { :species => tr.species_key(p), :level => p.level, :exp => (p.exp rescue nil),
          :pid => (p.personalID rescue nil), :uid => (p.pemk_uid rescue nil),
          :hp => p.hp, :totalhp => p.totalhp, :status => (p.status.to_s rescue nil),
          :iv => tr.stat_hash(p.iv), :ev => tr.stat_hash(p.ev),
          :moves => tr.move_ids(p), :pp => (p.moves || []).map { |m| m && m.pp },
          :ability => (p.ability_id.to_s rescue nil), :nature => tr.nature_of(p),
          :item => (p.item_id ? p.item_id.to_s : nil), :shiny => (p.shiny? rescue false),
          :gender => (p.gender rescue nil), :form => (p.form rescue 0),
          :happiness => (p.happiness rescue nil), :obtain_map => (p.obtain_map rescue nil),
          :foreign => (p.foreign? ? true : false rescue nil) }
      rescue StandardError
        nil
      end

      def end_state(p)
        { :hp => p.hp, :status => (p.status.to_s rescue nil), :exp => (p.exp rescue nil) }
      rescue StandardError
        nil
      end

      def record_hash
        h = { :v => 1, :mode => @mode.to_s, :seed => @seed, :map => @map,
              :init => @init, :rounds => @rounds, :switches => @switches, :runs => @runs,
              :outcome => @outcome,
              :draws => { :b => stream_hash(:b), :a => stream_hash(:a), :r => stream_hash(:r) },
              :truncated => @truncated, :desynced => @desynced }
        if @trainers   # a trainer battle: what a rebuild and an AI re-run need
          h.merge!(:kind => "trainer", :trainers => @trainers, :settings => @settings,
                   :confirms => @confirms, :forgets => @forgets)
        end
        h
      end

      def stream_hash(k)
        s = @streams[k]
        { :n => s[:n], :fp => hex(s[:fp]), :log => s[:log] }
      end
    end
  end
end

#===============================================================================
# Battle hooks — reopen + alias only (no engine edits). Every capture call is
# rescue-guarded; the aliases return exactly what the originals return.
#===============================================================================
class Battle
  attr_reader :pemk_rng_session

  unless method_defined?(:pemk_rng_orig_pbStartBattle)
    alias pemk_rng_orig_pbStartBattle pbStartBattle
    def pbStartBattle
      @pemk_rng_session = PEMK::BattleRng.arm_for(self)
      (@pemk_rng_session.snapshot_init(self) rescue nil) if @pemk_rng_session
      pemk_rng_orig_pbStartBattle
    ensure
      if (s = @pemk_rng_session)
        @pemk_rng_session = nil
        (s.snapshot_outcome(self) rescue nil) unless s.outcome?   # abnormal exit fallback
        (s.finalize_and_send rescue nil)
      end
    end

    alias pemk_rng_orig_pbRandom pbRandom
    def pbRandom(x)
      s = @pemk_rng_session
      return pemk_rng_orig_pbRandom(x) unless s

      s.draw(:b, x, -> { pemk_rng_orig_pbRandom(x) })
    rescue StandardError
      pemk_rng_orig_pbRandom(x)
    end

    alias pemk_rng_orig_pbCommandPhase pbCommandPhase
    def pbCommandPhase
      ret = pemk_rng_orig_pbCommandPhase
      (@pemk_rng_session.snapshot_round(self) rescue nil) if @pemk_rng_session
      ret   # preserve the original's return value (alias invariant)
    end

    alias pemk_rng_orig_pbSwitchInBetween pbSwitchInBetween
    def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
      ret = pemk_rng_orig_pbSwitchInBetween(idxBattler, checkLaxOnly, canCancel)
      (@pemk_rng_session.snapshot_switch(idxBattler, ret) rescue nil) if @pemk_rng_session
      ret
    end

    # Flee rolls draw through pbAIRandom but ARE replayed (choices re-register,
    # the AI never re-runs, the flee roll does) — route them to their own stream
    # via a context flag so replay can seed it independently. The invocation
    # itself is ALSO a captured event: the end-of-round "Use next Pokémon?" ->
    # "No" path is invisible in @choices and this is its only trace.
    alias pemk_rng_orig_pbRun pbRun
    def pbRun(idxBattler, duringBattle = false)
      s = @pemk_rng_session
      s.run_context = true if s
      ret = pemk_rng_orig_pbRun(idxBattler, duringBattle)
      (s.note_run(idxBattler, duringBattle, ret) rescue nil) if s
      ret
    ensure
      s.run_context = false if s
    end

    alias pemk_rng_orig_pbEndOfBattle pbEndOfBattle
    def pbEndOfBattle
      if (s = @pemk_rng_session)
        (s.snapshot_outcome(self) rescue nil)
        # A trainer battle's record leaves before its prize claim (made inside this call),
        # so the server holds the record the claim will name (trainer proof P2).
        (s.finalize_and_send rescue nil) if s.trainers
      end
      pemk_rng_orig_pbEndOfBattle
    end

    # Every yes/no the battle asks the player goes through here: a trainer battle's
    # record keeps the answers, in order.
    alias pemk_rng_orig_pbDisplayConfirm pbDisplayConfirm
    def pbDisplayConfirm(msg)
      ret = pemk_rng_orig_pbDisplayConfirm(msg)
      (@pemk_rng_session.note_confirm(ret) rescue nil) if @pemk_rng_session&.trainers
      ret
    end
  end
end

# Trainer proof P2: a trainer loaded for a battle asks its placement's seed at once.
# P4: a record the server has not acknowledged goes out again.
if defined?(EventHandlers)
  EventHandlers.add(:on_trainer_load, :pemk_trainer_seed,
    proc { |trainer| PEMK::BattleRng.ask_trainer_seed(trainer) })
  EventHandlers.add(:on_frame_update, :pemk_battle_records, proc { PEMK::BattleRng.send_records })
end

# B2: the battle a trainer is loaded for - a badge's battle is fought alone only there.
if defined?(TrainerBattle) && TrainerBattle.respond_to?(:start_core) &&
   !TrainerBattle.respond_to?(:pemk_rng_orig_start_core)
  class TrainerBattle
    class << self
      alias_method :pemk_rng_orig_start_core, :start_core
      def start_core(*args)
        (PEMK::BattleRng.core_begin(args) rescue nil)
        pemk_rng_orig_start_core(*args)
      ensure
        (PEMK::BattleRng.core_end rescue nil)
      end
    end
  end
end

class Battle::AI
  unless method_defined?(:pemk_rng_orig_pbAIRandom)
    alias pemk_rng_orig_pbAIRandom pbAIRandom
    def pbAIRandom(x)
      s = (@battle.pemk_rng_session rescue nil)
      return pemk_rng_orig_pbAIRandom(x) unless s

      s.draw(:a, x, -> { pemk_rng_orig_pbAIRandom(x) })
    rescue StandardError
      pemk_rng_orig_pbAIRandom(x)
    end
  end
end
