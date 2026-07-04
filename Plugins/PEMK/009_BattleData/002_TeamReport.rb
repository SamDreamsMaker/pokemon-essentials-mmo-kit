#===============================================================================
# PEMK :: TeamReport  (client side — M4 Layer D D1, full-stat team legality report)
#-------------------------------------------------------------------------------
# Builds the player's party as a NON-Marshal, primitive, server-legible team block
# (species/level/ivs/evs/moves/ability/nature/item) and lets Sync push it as a
# :team_check whenever the party changes. The server (TeamAudit) validates legality
# against the exported battle data and logs illegal teams — detection-only in D1.
#
# Unlike the battle party blob (005_Battle/002_BattleSetup.rb, a Marshal.dump the
# server never decodes), this rides the PRIMITIVE envelope so the server can actually
# read + audit it, without the Marshal.load RCE surface. Everything is rescue-guarded:
# a build fault just skips this pass, never disrupts the game.
#===============================================================================
module PEMK
  module TeamReport
    STATS = %i[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze

    module_function

    # -> Array of primitive mon Hashes (String-keyed), or nil if there's no party.
    # A single malformed mon is skipped (rescued per-mon), never suppressing the rest.
    def build
      return nil unless $player && $player.party

      $player.party.map { |p| (mon(p) rescue nil) if p }.compact
    rescue StandardError => e
      PEMK.log("team: build error #{e.class}: #{e.message}")
      nil
    end

    def mon(p)
      {
        "species" => species_key(p),
        "level"   => p.level,
        "ivs"     => stat_hash(p.iv),
        "evs"     => stat_hash(p.ev),
        "moves"   => move_ids(p),
        "ability" => sym_or_nil(p.ability_id),
        "nature"  => nature_of(p),
        "item"    => sym_or_nil(p.item_id)
      }
    end

    # The FORM-resolved species id ("ROTOM_5" for Rotom-Wash), matching the export key.
    # Sending the base id (p.species) would audit an alt-form mon against form-0 data —
    # a systematic false illegal_move/illegal_ability for every alt-form staple. Falls
    # back to the base id if species_data is unavailable.
    def species_key(p)
      sd = (p.species_data rescue nil)
      (sd && sd.id) ? sd.id.to_s : p.species.to_s
    end

    def move_ids(p)
      (p.moves || []).map { |m| (m && m.id) ? m.id.to_s : nil }.compact
    end

    def stat_hash(h)
      out = {}
      return out unless h

      STATS.each do |s|
        v = (h[s] rescue nil)
        out[s.to_s] = v if v.is_a?(Integer)
      end
      out
    end

    def nature_of(p)
      n = (p.nature rescue nil)          # computes + memoizes if unset; returns a Nature
      return n.id.to_s if n && n.id

      sym_or_nil(p.nature_id)
    end

    def sym_or_nil(v)
      v ? v.to_s : nil
    end

    # :team_ack telemetry — log when the server flags our team (visible while testing).
    def on_ack(msg)
      PEMK.log("team: server flagged team ILLEGAL (seq #{msg[:seq]})") if msg && msg[:legal] == false
    end
  end
end
