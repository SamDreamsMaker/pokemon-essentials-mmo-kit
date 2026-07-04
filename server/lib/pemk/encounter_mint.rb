# frozen_string_literal: true

require "securerandom"

module PEMK
  # M4 Layer D D2: server-authoritative wild-encounter minting. The server rolls the
  # wild Pokémon's SLOT (species + level) from the Layer A encounter tables (world.json,
  # via WorldData#encounters) and its IDENTITY {personalID, iv[6], shiny} with a
  # cryptographic RNG the client does not have — so a client can no longer choose what
  # appears, force a shiny, or force IVs. The client only ADOPTS the mint and renders it.
  #
  # It reproduces choose_wild_pokemon's DISTRIBUTION (weighted slot pick, inclusive level
  # range) — not the client's exact RNG sequence, which is unnecessary since the server
  # is authoritative. Identity fields:
  #   personalID  32-bit — the client derives nature/gender/ability from it (as the game
  #               does), so those are server-determined without extra fields;
  #   iv[6]       0..31, order [HP, ATTACK, DEFENSE, SPECIAL_ATTACK, SPECIAL_DEFENSE, SPEED];
  #   shiny       explicit boolean — shininess normally depends on the player's trainer ID
  #               (personalID XOR owner.id), which the server can't see, so it is dictated
  #               directly and the client sets pkmn.shiny to it.
  #
  # Honest gap (disclosed): client-side generation influences that are ability/item CODE
  # (Shiny Charm / chaining odds, Synchronize nature, Cute Charm gender, Compound Eyes
  # held item, Static/Magnet-Pull type bias) are NOT reproduced here — the server rolls
  # the base distribution. Folding them in is later work; for now they simply don't apply
  # under server mint.
  class EncounterMint
    IV_STATS      = 6
    IV_MAX        = 31
    SHINY_CHANCE  = 16       # gen6+: d < 16 ...
    SHINY_SPACE   = 65_536   # ... out of 65536  ==  1/4096
    PID_SPACE     = 2**32

    def initialize(world_data, logger: nil, rng: SecureRandom)
      @world = world_data
      @log   = logger || ->(_m) {}
      @rng   = rng   # must respond to random_number(n) -> 0..n-1
    end

    # Roll a full wild encounter for (map_id, enctype). -> Hash | nil (no table here).
    def roll(map_id, enctype)
      slots = table_slots(map_id, enctype)
      return nil unless slots

      species, level = pick_slot(slots)
      return nil unless species

      {
        "species" => species,
        "level"   => level,
        "pid"     => @rng.random_number(PID_SPACE),
        "iv"      => Array.new(IV_STATS) { @rng.random_number(IV_MAX + 1) },
        "shiny"   => @rng.random_number(SHINY_SPACE) < SHINY_CHANCE
      }
    end

    # Is +species+ a legal wild encounter for (map_id, enctype)? (D2 shadow detection:
    # a client reporting a species absent from the table is fabricating an encounter.)
    def legal?(map_id, enctype, species)
      slots = table_slots(map_id, enctype)
      return nil unless slots   # unjudgeable — no table for this map/type (unexported)

      want = species.to_s
      slots.any? { |s| s.is_a?(Array) && s[1].to_s == want }
    end

    # The raw slot list [[weight, "SPECIES", min, max], ...] for (map_id, enctype), or nil
    # when there's no table (map unexported / no such encounter type). Version 0 (default).
    def table_slots(map_id, enctype)
      enc = @world.encounters(map_id)
      return nil unless enc.is_a?(Hash)

      ver = enc["0"] || enc.values.find { |v| v.is_a?(Hash) }
      return nil unless ver.is_a?(Hash)

      t = ver[enctype.to_s]
      return nil unless t.is_a?(Hash)

      s = t["slots"]
      s.is_a?(Array) && !s.empty? ? s : nil
    end

    private

    # Weighted pick by slot[0], then level = min + rand(max-min+1) inclusive — mirrors
    # choose_wild_pokemon's distribution. Malformed slots are skipped defensively.
    def pick_slot(slots)
      valid = slots.select do |s|
        s.is_a?(Array) && s.length >= 4 && s[0].is_a?(Integer) && s[0] > 0 && s[1] &&
          s[2].is_a?(Integer) && s[3].is_a?(Integer)
      end
      return [nil, nil] if valid.empty?

      total = valid.sum { |s| s[0] }
      r = @rng.random_number(total)
      valid.each do |s|
        r -= s[0]
        next if r >= 0

        min = s[2]
        max = [s[3], min].max
        return [s[1].to_s, min + @rng.random_number(max - min + 1)]
      end
      [nil, nil]
    end
  end
end
