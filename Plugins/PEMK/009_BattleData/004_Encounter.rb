#===============================================================================
# PEMK :: Encounter  (client side — M4 Layer D D2, server-authoritative wild encounters)
#-------------------------------------------------------------------------------
# What the server mints (or audits) is the encounter table's OWN roll: the [species,
# level] PokemonEncounters#choose_wild_pokemon gives a step, a rod, Headbutt, Rock Smash
# or Sweet Scent, as it reaches WildBattle.generate_foes. A roll a handler of
# :on_wild_species_chosen writes to (a roaming Pokémon, the Poké Radar's chain, a plugin's
# swarm) - even with the values it held - is the game's, like an event's battle
# (WildBattle.start(:MEW, 30)), a roamer's own generation or a scaling-level map: built by
# the game, neither minted nor reported. A plugin that starts a battle from a table roll
# of its own says so with PEMK::Encounter.table_roll(roll, encounter_type).
#
# With a mode other than off, :on_wild_species_chosen handlers get a copy of the roll (a
# PEMK::Encounter::Probe, an Array) whose values are copied back after them: a handler
# that keeps the array to write it later, or tests its class or identity, sees the copy.
#
# Modes (adopted from the login snapshot):
#   off    — local roll, no traffic (nothing changes).
#   shadow — local roll UNCHANGED, but the client fire-and-forget REPORTS the table's
#            roll (map, enctype, species, level) so the server audits it vs the Layer A tables.
#   on     — the client REQUESTS a server mint for the table's roll and BUILDS the wild
#            Pokémon from the server's {species, level, personalID, iv[6], shiny}, so the
#            server owns what appears, its level, shininess and IVs. The CLIENT is a pure
#            observer. Fail-open: a deny / timeout / offline / build fault falls back to a
#            local roll — wild encounters must never just stop.
#
# Everything is rescue-guarded: a fault degrades to the untouched local encounter.
#===============================================================================
module PEMK
  module Encounter
    ROLLS_MAX  = 8    # table rolls remembered (an encounter a Repel turned away leaves one)
    GRANTS_MAX = 16   # personal ids built from a grant (the catch seam asks for those only)

    @mode   = :off   # server-advertised enforcement mode
    @seq    = 0      # client-local request id, to correlate the mint reply
    @inbox  = {}     # seq => reply hash (delete-on-read)
    @rolls  = {}.compare_by_identity   # the roll itself => { species:, level:, type:, taken: } (newest last)
    @frame  = nil    # the table's own rolls of the generate_foes call under way: [[species, level, type], ...]
    @granted = []    # personal ids of wild Pokémon built from a grant (newest last)
    @seams  = {}     # name => [reader, the method PEMK installed]
    @seams_said = false
    @stray_said = false

    # A copy of a roll that notes a write: the handlers of :on_wild_species_chosen get it.
    class Probe < Array
      WRITERS = %i[[]= replace fill clear insert push << unshift prepend append concat pop shift
                   delete delete_at delete_if slice! compact! flatten! reverse! rotate! shuffle!
                   sort! sort_by! uniq! map! collect! select! filter! reject! keep_if].freeze
      WRITERS.each do |name|
        next unless Array.method_defined?(name)

        define_method(name) do |*args, &blk|
          @written = true
          super(*args, &blk)
        end
      end

      def written?
        @written == true
      end
    end

    module_function

    def reset
      @mode    = :off
      @seq     = 0
      @inbox   = {}
      @rolls   = {}.compare_by_identity
      @frame   = nil
      @granted = []
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
      check_seams if @mode != :off
    end

    def mode; @mode; end

    # A live, authenticated online client.
    def online?
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    def shadow?;    @mode == :shadow && online?; end
    def enforcing?; @mode == :on     && online?; end

    # A map that rescales wild levels to the party (ScaleWildEncounterLevels flag) can't be
    # server-minted — the server has no party levels, and such maps list every slot at level
    # 1 expecting the local rescale (:level_depends_on_party). So we leave those LOCAL even in
    # `on`, or they'd spawn level-1 mons.
    def scaling_level_map?
      !!($game_map && $game_map.metadata && $game_map.metadata.has_flag?("ScaleWildEncounterLevels"))
    rescue StandardError
      false
    end

    # --- the table's own rolls --------------------------------------------------
    # A [species, level] the table rolled for +type+, with the table's odds (one roll: the
    # Poké Radar's rarer-slot rolls are not).
    def note_roll(arr, type, chance_rolls = 1)
      return unless @mode != :off && arr.is_a?(Array) && type && chance_rolls == 1

      @rolls.shift while @rolls.size >= ROLLS_MAX
      @rolls[arr] = { species: arr[0], level: arr[1], type: type, taken: false }
    end

    # For a plugin that starts a battle from a table roll of its own.
    def table_roll(arr, type)
      note_roll(arr, type)
    end

    def roll_of(arr)
      arr.is_a?(Array) ? @rolls[arr] : nil
    end

    # :on_wild_species_chosen with a roll: what its handlers get instead (nil: not a roll).
    def probe_for(arr)
      roll_of(arr) ? Probe.new(arr) : nil
    end

    # ... and once they ran: a write, whatever it wrote, makes the roll theirs.
    def after_chosen(arr, probe)
      rec = roll_of(arr)
      rec[:taken] = true if rec && probe.written?
    end

    # WildBattle.generate_foes(*args): the table's own rolls among +args+, as rolled, are
    # this call's frame. -> the frame it replaces (a nested call puts it back).
    def open_frame(args)
      outer = @frame
      entries = args.filter_map do |a|
        rec = roll_of(a)
        next unless rec

        @rolls.delete(a)   # a roll mints one battle
        next if rec[:taken] || a[0] != rec[:species] || a[1] != rec[:level]

        [GameData::Species.get(a[0]).id, a[1], rec[:type]]
      end
      @frame = entries
      outer
    end

    def close_frame(outer)
      @frame = outer
    end

    # pbGenerateWildPokemon(species, level): the frame's entry for them, taken | nil.
    def take_entry(species, level)
      i = @frame&.index { |s, l, _| s == species && l == level }
      i && @frame.delete_at(i)
    end

    # A wild Pokémon generated outside a wild battle's start while an encounter type is set
    # (an overworld spawn plugin's own, say): the game's - said once.
    def note_stray
      return if @stray_said || @mode == :off || !@frame.nil?
      return unless ($game_temp && $game_temp.encounter_type rescue nil)

      @stray_said = true
      PEMK.log("encounter: a wild Pokemon was generated outside a wild battle's start (a plugin's own " \
               "encounter?) - the game's, neither minted nor reported; PEMK::Encounter.table_roll marks a table roll")
    end

    # --- the seams ---------------------------------------------------------------
    # A script loaded after PEMK that redefines one may no longer hand the table's roll on
    # as it was: nothing is minted or reported then. Said once, as a mode other than off is
    # adopted.
    def note_seam(name, reader)
      @seams[name] = [reader, reader.call]
    rescue StandardError
      nil
    end

    def check_seams
      return if @seams_said

      changed = @seams.filter_map { |name, (reader, mine)| name unless (reader.call rescue nil) == mine }
      return if changed.empty?

      @seams_said = true
      PEMK.log("encounter: a script loaded after PEMK redefines #{changed.join(', ')} - if it no longer " \
               "passes the table's roll on as it is, wild encounters stay the game's (nothing minted or reported)")
    rescue StandardError
      nil
    end

    # --- shadow / on ---------------------------------------------------------------
    # SHADOW: fire-and-forget report of a locally-rolled encounter (no reply).
    def report(map, enctype, species, level)
      PEMK.send_message(:type => :encounter_report, :map => map, :enctype => enctype.to_s,
                        :species => species.to_s, :level => level, :version => table_version)
    rescue StandardError => e
      PEMK.log("encounter: report error #{e.class}: #{e.message}")
    end

    # The game's encounter version (a story event moves it on): which of the map's tables
    # the game rolls from.
    def table_version
      v = ($PokemonGlobal && $PokemonGlobal.encounter_version) rescue nil
      v.is_a?(Integer) ? v : 0
    end

    # ON: request a server mint for this map and +type+ and BUILD the wild Pokémon from it.
    # -> Pokemon | nil (deny / timeout / offline / build fault -> caller rolls local).
    def request_and_build(type)
      map = ($game_map && $game_map.map_id) rescue nil
      return nil unless map && type

      grant = request(map, type)
      return nil unless grant && grant[:type] == :encounter_grant

      build_from_grant(grant)
    end

    def request(map, enctype)
      @inbox.clear   # a new encounter supersedes any late reply from a timed-out one
      @seq += 1
      PEMK.send_message(:type => :encounter_req, :map => map, :enctype => enctype.to_s, :seq => @seq,
                        :version => table_version)
      wait_for(@seq)
    end

    # Dispatch routes :encounter_grant / :encounter_deny here (delete-on-read by seq).
    def on_reply(msg)
      s = msg && msg[:seq]
      @inbox[s] = msg if s.is_a?(Integer)
    end

    def take(seq)
      @inbox.delete(seq)
    end

    # Block until the reply for +seq+ arrives or the deadline passes, pumping the overworld
    # loop (Graphics.update IS the SDK network pump). Aborts if the link drops. -> reply | nil.
    def wait_for(seq)
      deadline = mono + Config::ENCOUNTER_GRANT_TIMEOUT
      loop do
        r = take(seq)
        return r if r
        return nil if mono >= deadline

        c = PEMK.client
        return nil unless c && c.connected?

        Graphics.update
        Input.update
        (pbUpdateSceneMap rescue nil)
      end
    rescue StandardError => e
      PEMK.log("encounter: wait error #{e.class}: #{e.message}")
      nil
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end

    # Build the wild Pokémon from the server mint. nature/gender/ability derive from the
    # server personalID (as the game does); shininess is set EXPLICITLY because it normally
    # depends on the player's trainer id, which the server can't see. Building without going
    # through pbGenerateWildPokemon's body also skips the local IV/shiny re-randomizers.
    def build_from_grant(g)
      sp  = g[:species]
      lvl = g[:level]
      return nil unless sp && lvl.is_a?(Integer)

      pkmn = Pokemon.new(sp.to_s.to_sym, lvl, $player, false)   # withMoves=false; reset_moves below
      pkmn.personalID = g[:pid] if g[:pid].is_a?(Integer)
      iv = g[:iv]
      if iv.is_a?(Array) && iv.length == 6
        [:HP, :ATTACK, :DEFENSE, :SPECIAL_ATTACK, :SPECIAL_DEFENSE, :SPEED].each_with_index do |s, i|
          pkmn.iv[s] = iv[i].to_i if iv[i].is_a?(Integer)
        end
      end
      pkmn.shiny       = (g[:shiny] == true)   # explicit — do not let it derive from the player TID
      pkmn.super_shiny = false                  # server mints regular shininess only (own it fully)
      pkmn.nature      = nil                    # clear the stale @nature memo; re-derives from the new pid
      pkmn.calc_stats
      pkmn.reset_moves
      # Lock getForm-style forms (season/trim) as pbGenerateWildPokemon does; getFormOnCreation
      # forms (Unown/Burmy/…) are already set by Pokemon.new (recheck_form defaults true).
      (pkmn.form_simple = pkmn.form if MultipleForms.hasFunction?(pkmn.species, "getForm")) rescue nil
      # D7: the battle seed born with this mint — stash for BattleRng's arm-at-battle-start
      # (single-use, bound to this pid; absent when the server's rng seam is off).
      (PEMK::BattleRng.note_grant(g[:battle_seed], g[:pid]) rescue nil)
      note_granted(pkmn.personalID)
      pkmn
    rescue StandardError => e
      PEMK.log("encounter: build error #{e.class}: #{e.message}")
      nil
    end

    def note_granted(pid)
      @granted.shift while @granted.size >= GRANTS_MAX
      @granted << pid
    end

    # Was +pkmn+ built from a server grant? Only such a foe has a mint the server can judge
    # a catch against.
    def granted?(pkmn)
      pid = (pkmn.personalID rescue nil)
      !pid.nil? && @granted.include?(pid)
    end
  end
end

# The table's roll, as choose_wild_pokemon gives it (steps, rods, Headbutt, Rock Smash,
# Sweet Scent, and the Poké Radar's own rolls, which its handler copies: those are its).
if defined?(PokemonEncounters) && PokemonEncounters.method_defined?(:choose_wild_pokemon) &&
   !PokemonEncounters.method_defined?(:pemk_orig_choose_wild_pokemon)
  class PokemonEncounters
    alias pemk_orig_choose_wild_pokemon choose_wild_pokemon
    def choose_wild_pokemon(enc_type, chance_rolls = 1)
      ret = pemk_orig_choose_wild_pokemon(enc_type, chance_rolls)
      (PEMK::Encounter.note_roll(ret, enc_type, chance_rolls) rescue nil)
      ret
    end
  end
end

# The handlers that may take a roll over work on a copy that notes a write; what they wrote
# goes back into the roll itself.
if defined?(EventHandlers) && EventHandlers.respond_to?(:trigger) &&
   !EventHandlers.respond_to?(:pemk_orig_trigger)
  module EventHandlers
    class << self
      alias pemk_orig_trigger trigger
      def trigger(event, *args)
        probe = (PEMK::Encounter.probe_for(args[0]) rescue nil) if event == :on_wild_species_chosen
        return pemk_orig_trigger(event, *args) unless probe

        begin
          pemk_orig_trigger(event, probe, *args.drop(1))
        ensure
          args[0].replace(probe) if probe.written?
          (PEMK::Encounter.after_chosen(args[0], probe) rescue nil)
        end
      end
    end
  end
end

# Which of a battle's foes are the table's own rolls, for the generations it makes.
if defined?(WildBattle) && WildBattle.respond_to?(:generate_foes) &&
   !WildBattle.respond_to?(:pemk_orig_generate_foes)
  class WildBattle
    class << self
      alias pemk_orig_generate_foes generate_foes
      def generate_foes(*args)
        outer = (PEMK::Encounter.open_frame(args) rescue :none)
        begin
          pemk_orig_generate_foes(*args)
        ensure
          (PEMK::Encounter.close_frame(outer) rescue nil) unless outer == :none
        end
      end
    end
  end
end

# Every wild Pokémon is generated here; only a table's own roll is minted or reported.
# Guarded so it loads cleanly in a headless harness and aliases at most once.
if defined?(pbGenerateWildPokemon) && !defined?(pemk_orig_pbGenerateWildPokemon)
  alias pemk_orig_pbGenerateWildPokemon pbGenerateWildPokemon
  def pbGenerateWildPokemon(species, level, isRoamer = false)
    entry = isRoamer ? nil : (PEMK::Encounter.take_entry(species, level) rescue nil)
    (PEMK::Encounter.note_stray rescue nil) unless entry || isRoamer
    # ON: the server owns the table's encounter — build from its mint (client = observer).
    if entry && (PEMK::Encounter.enforcing? rescue false) && !(PEMK::Encounter.scaling_level_map? rescue false)
      mon = (PEMK::Encounter.request_and_build(entry[2]) rescue nil)
      if mon
        (PEMK::Reward.note_foe(mon) rescue nil)   # D4: record the foe for the reward window
        return mon
      end
      # deny / timeout / offline / build fault -> fall through to a local roll
    end
    pkmn = pemk_orig_pbGenerateWildPokemon(species, level, isRoamer)
    (PEMK::Reward.note_foe(pkmn) rescue nil) unless isRoamer   # D4
    # SHADOW: report the table's roll for audit - its own species id, a form's included.
    if entry && pkmn && (PEMK::Encounter.shadow? rescue false)
      map = ($game_map && $game_map.map_id) rescue nil
      (PEMK::Encounter.report(map, entry[2], entry[0], pkmn.level) rescue nil) if map
    end
    pkmn
  end
end

PEMK::Encounter.note_seam("PokemonEncounters#choose_wild_pokemon", -> { PokemonEncounters.instance_method(:choose_wild_pokemon) })
PEMK::Encounter.note_seam("EventHandlers.trigger", -> { EventHandlers.method(:trigger) })
PEMK::Encounter.note_seam("WildBattle.generate_foes", -> { WildBattle.method(:generate_foes) })
PEMK::Encounter.note_seam("pbGenerateWildPokemon", -> { Object.instance_method(:pbGenerateWildPokemon) })
