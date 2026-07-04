#===============================================================================
# PEMK :: Encounter  (client side — M4 Layer D D2, server-authoritative wild encounters)
#-------------------------------------------------------------------------------
# Every wild-Pokémon generation path (grass / cave / water steps, fishing, rock smash,
# headbutt, sweet scent, roamers) funnels through the global pbGenerateWildPokemon, so
# we alias exactly that one seam.
#
# D2 SHADOW (this milestone): the local roll is unchanged; the client just REPORTS the
# encounter it generated (map, enctype, species, level) so the server can audit it against
# the Layer A encounter tables (a species absent from the table = a fabricated encounter)
# and validate its own roller against real play — before the mint is enforced.
#
# D2 ON (next milestone): the client will instead REQUEST a server mint and build the wild
# Pokémon from the server's {species, level, personalID, iv[6], shiny}, so the server owns
# what appears (client = pure observer). The `on` mode reports like shadow for now.
#
# Mode (off/shadow/on) is adopted from the login snapshot. Everything is rescue-guarded:
# a fault degrades to the untouched local encounter, never disrupting the overworld.
#===============================================================================
module PEMK
  module Encounter
    @mode = :off   # server-advertised enforcement mode (adopted at login)

    module_function

    def reset
      @mode = :off
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end

    # We act (report now; adopt a mint later) only when the server is enforcing AND we're
    # a live, authenticated online client. Any false -> the untouched local encounter.
    def active?
      return false if @mode == :off
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # SHADOW telemetry: fire-and-forget report of a locally-rolled encounter. No reply.
    def report(map, enctype, species, level)
      PEMK.send_message(:type => :encounter_report, :map => map, :enctype => enctype.to_s,
                        :species => species.to_s, :level => level)
    rescue StandardError => e
      PEMK.log("encounter: report error #{e.class}: #{e.message}")
    end
  end
end

# Intercept the single wild-Pokémon generation seam. In shadow/on, report the mon the
# client generated locally for server audit; the local roll is unchanged in D2 part 1.
# (part 2 will make :on adopt a server mint here instead.) Guarded so it loads cleanly in
# a headless harness (pbGenerateWildPokemon undefined there) and aliases at most once.
if defined?(pbGenerateWildPokemon) && !defined?(pemk_orig_pbGenerateWildPokemon)
  alias pemk_orig_pbGenerateWildPokemon pbGenerateWildPokemon
  def pbGenerateWildPokemon(species, level, isRoamer = false)
    pkmn = pemk_orig_pbGenerateWildPokemon(species, level, isRoamer)
    if (PEMK::Encounter.active? rescue false)
      map     = ($game_map && $game_map.map_id) rescue nil
      enctype = ($game_temp && $game_temp.encounter_type) rescue nil
      (PEMK::Encounter.report(map, enctype, pkmn.species, pkmn.level) rescue nil) if map && enctype && pkmn
    end
    pkmn
  end
end
