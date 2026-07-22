#===============================================================================
# PEMK :: Encounter  (client side — M4 Layer D D2, server-authoritative wild encounters)
#-------------------------------------------------------------------------------
# Every wild-Pokémon generation path (grass / cave / water steps, fishing, rock smash,
# headbutt, sweet scent) funnels through the global pbGenerateWildPokemon, so we alias
# exactly that one seam.
#
# Modes (adopted from the login snapshot):
#   off    — local roll, no traffic (nothing changes).
#   shadow — local roll UNCHANGED, but the client fire-and-forget REPORTS what it rolled
#            (map, enctype, species, level) so the server audits it vs the Layer A tables.
#   on     — the client REQUESTS a server mint and BUILDS the wild Pokémon from the
#            server's {species, level, personalID, iv[6], shiny}, so the server owns what
#            appears, its level, shininess and IVs. The CLIENT is a pure observer.
#            Fail-open: a deny / timeout / offline / build fault falls back to a local
#            roll — wild encounters must never just stop.
#
# Everything is rescue-guarded: a fault degrades to the untouched local encounter.
#===============================================================================
module PEMK
  module Encounter
    @mode  = :off   # server-advertised enforcement mode
    @seq   = 0      # client-local request id, to correlate the mint reply
    @inbox = {}     # seq => reply hash (delete-on-read)

    module_function

    def reset
      @mode  = :off
      @seq   = 0
      @inbox = {}
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
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

    # SHADOW: fire-and-forget report of a locally-rolled encounter (no reply).
    def report(map, enctype, species, level)
      PEMK.send_message(:type => :encounter_report, :map => map, :enctype => enctype.to_s,
                        :species => species.to_s, :level => level)
    rescue StandardError => e
      PEMK.log("encounter: report error #{e.class}: #{e.message}")
    end

    # ON: request a server mint for the current tile's encounter and BUILD the wild Pokémon
    # from it. -> Pokemon | nil (deny / timeout / offline / build fault -> caller rolls local).
    def request_and_build(_species, _level)
      map     = ($game_map  && $game_map.map_id) rescue nil
      enctype = ($game_temp && $game_temp.encounter_type) rescue nil
      return nil unless map && enctype

      grant = request(map, enctype)
      return nil unless grant && grant[:type] == :encounter_grant

      build_from_grant(grant)
    end

    def request(map, enctype)
      @inbox.clear   # a new encounter supersedes any late reply from a timed-out one
      @seq += 1
      PEMK.send_message(:type => :encounter_req, :map => map, :enctype => enctype.to_s, :seq => @seq)
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
      pkmn
    rescue StandardError => e
      PEMK.log("encounter: build error #{e.class}: #{e.message}")
      nil
    end
  end
end

# Intercept the single wild-Pokémon generation seam (all step/fishing/field paths funnel
# through it). Guarded so it loads cleanly in a headless harness (pbGenerateWildPokemon
# undefined there) and aliases at most once.
if defined?(pbGenerateWildPokemon) && !defined?(pemk_orig_pbGenerateWildPokemon)
  alias pemk_orig_pbGenerateWildPokemon pbGenerateWildPokemon
  def pbGenerateWildPokemon(species, level, isRoamer = false)
    # ON: the server owns the encounter — build from its mint (client = observer). Roamers
    # are a distinct cached-mint path, left local in D2.
    if !isRoamer && (PEMK::Encounter.enforcing? rescue false) && !(PEMK::Encounter.scaling_level_map? rescue false)
      mon = (PEMK::Encounter.request_and_build(species, level) rescue nil)
      if mon
        (PEMK::Reward.note_foe(mon) rescue nil)   # D4: record the foe for the reward window
        return mon
      end
      # deny / timeout / offline / build fault -> fall through to a local roll
    end
    pkmn = pemk_orig_pbGenerateWildPokemon(species, level, isRoamer)
    (PEMK::Reward.note_foe(pkmn) rescue nil) unless isRoamer   # D4
    # SHADOW: report the local roll for audit (only when not enforcing).
    if !isRoamer && (PEMK::Encounter.shadow? rescue false)
      map     = ($game_map  && $game_map.map_id) rescue nil
      enctype = ($game_temp && $game_temp.encounter_type) rescue nil
      (PEMK::Encounter.report(map, enctype, pkmn.species, pkmn.level) rescue nil) if map && enctype && pkmn
    end
    pkmn
  end
end
