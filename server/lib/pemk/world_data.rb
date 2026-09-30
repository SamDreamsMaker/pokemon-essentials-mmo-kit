# frozen_string_literal: true

require "json"

module PEMK
  # Read-only server model of the game world (Milestone 4). Loaded ONCE at boot from
  # a build-time JSON export (server/data/world.json) produced IN-ENGINE by the
  # client's "PEMK: Export World" debug action. The server NEVER reads the RMXP
  # .rxdata maps directly — that would need the engine's RPG/Table/Tone classes and a
  # Marshal.load of attacker-influenceable files, the exact RCE surface M4 forbids. It
  # only ever consumes plain JSON.
  #
  # Schema v2 carries the full static world the layered anti-cheat needs:
  #   per-map: objects[] (item balls — Layer A/C), passability grid (Layer B no-clip),
  #            warps[] (Layer B/C transfer legality), heal (Layer B respawn whitelist),
  #            encounters (Layer D);
  #   top-level: connections[] (edge map-stitching), home + start (respawn/genesis).
  # Every section is OPTIONAL (absent -> that check no-ops), mirroring the empty?/
  # map_known? tolerance, so partial exports never brick anything.
  #
  # Passability is a per-map array of H hex-nibble row strings (W chars each), where
  # the nibble is the ground tile's RMXP passage bits and 0x0f ('f') == fully blocked.
  # walkable? flags ONLY an explicit 'f' (never a missing grid), so the position audit
  # is conservative by construction. Water is a per-map array of H row strings: 'w'
  # where a surfer may be, 'd' where Dive also goes down or comes up, 'x' deep water
  # under a rock (a diver may come up there, no surfer may be there), '.' elsewhere;
  # an export with water_marks says so for every map (no grid = no water there).
  #
  # Boot policy (unchanged, asymmetric): ABSENT export -> tolerated (empty model + one
  # warning); PRESENT-but-INVALID (unparseable / wrong schema_version / wrong shape)
  # -> BOOT ERROR, so a stale/corrupt world never boots silently.
  class WorldData
    SCHEMA_VERSION  = 3
    # v2 exports stay valid: v3 only ADDS the optional :flags manifest, so an operator
    # who has not re-exported since the sovereign-variables work keeps a working server
    # (they simply have no manifest, which means all-local — today's behaviour).
    ACCEPTED_VERSIONS = [2, 3].freeze
    BLOCKED = "f"   # a passability nibble of 0x0f == fully blocked

    def initialize(path, expected_version: ACCEPTED_VERSIONS, logger: nil)
      @log          = logger || ->(_m) {}
      @by_tile      = {}    # [map,x,y] => frozen object hash
      @maps         = {}    # map_id => { name:, width:, height:, count: }
      @passable     = {}    # map_id => frozen Array of frozen row strings
      @ledges       = {}    # map_id => frozen Hash { [x,y] => true }
      @water        = {}    # map_id => frozen Array of frozen row strings ('.', 'w', 'd', 'x')
      @dive_maps    = {}    # map_id => the map Dive takes a player down to
      @surface_maps = {}    # dive map_id => the map a diver comes up to (the engine's own pick)
      @water_marks  = false # does the export mark water? (then a map without a grid has none)
      @warps_by_map = {}    # map_id => frozen Array of frozen warp hashes
      @heal         = {}    # map_id => [map,x,y]
      @connections  = []    # frozen Array of raw 6-int conn arrays
      @home         = nil   # [map,x,y,dir]
      @start        = nil   # [map,x,y]
      @encounters   = {}    # map_id => raw encounters hash
      @trainers_by_map = {} # map_id => frozen Array of [type, name, version]
      @trainer_places  = {} # map_id => { event_id => frozen Array of [type, name, version, rematch, repeatable] } (M1a)
      @trainer_marks   = false # does the export say which battles can be fought again?
      @partners        = nil   # frozen Array of [type, name, version] the game registers as partners
      @badge_sources   = nil   # badge => frozen Array of sources (badge authority B0); nil: not exported
      @badge_unknown   = []    # the badge sets the export could not read
      @gifts        = {}    # [map,event_id] => frozen gift/prize object (step 6 payout gate)
      @shops        = {}    # [map,event_id] => frozen mart / bp_shop object (item authority)
      @loaded       = false
      load!(path, expected_version)
    end

    def loaded?; @loaded; end
    def empty?;  @maps.empty?; end
    def map_known?(map_id); @maps.key?(map_id); end

    # --- objects (Layer A/C) ---------------------------------------------------
    # -> frozen object hash { "kind"=>, "item"=>, "event_id"=>, "x"=>, "y"=> } | nil
    def object_at(map_id, x, y)
      @by_tile[[map_id, x, y]]
    end

    # --- passability (Layer B no-clip) -----------------------------------------
    # true = walkable, false = fully blocked ('f'), nil = unjudgeable (no grid for
    # this map, OR the coord is outside the grid). Out-of-bounds is NOT a wall: at a
    # map-connection seam the player's local x/y legitimately goes negative / past
    # the edge while stepping onto a stitched neighbour, so it must never read as a
    # no-clip. The audit only ever flags an explicit `false`.
    def walkable?(map_id, x, y)
      grid = @passable[map_id]
      return nil unless grid
      return nil if y < 0 || y >= grid.length

      row = grid[y]
      return nil if x < 0 || x >= row.length

      row[x] != BLOCKED
    end

    # A one-way ledge tile (hop-over). Lets the position audit accept a 2-tile ledge
    # jump instead of flagging it as a teleport.
    def ledge?(map_id, x, y)
      s = @ledges[map_id]
      s ? s.key?([x, y]) : false
    end

    # --- water (Layer B for surfers and divers) --------------------------------
    # The passability grid counts water as walls: these say which of them a surfer
    # crosses, and where Dive goes down or comes up.
    def water_marks?; @water_marks; end

    # true = a surfer may be here, false = no water, nil = the export does not say (it
    # predates the water marks, or the tile is outside the grid).
    def water?(map_id, x, y)
      return (@water_marks ? false : nil) unless @water.key?(map_id)

      c = water_char(map_id, x, y)
      c && (c == "w" || c == "d")
    end

    # Where Dive goes down, and where a diver comes up on the map above ('x': deep water
    # under a rock, which the engine lets a diver come up onto but no surfer reach).
    def deep?(map_id, x, y)
      c = water_char(map_id, x, y)
      c == "d" || c == "x"
    end

    # The map Dive takes a player down to from +map_id+ | nil.
    def dive_map(map_id)
      @dive_maps[map_id]
    end

    # The map a diver on +map_id+ comes up to | nil (the first whose DiveMap it is).
    def surface_map(map_id)
      @surface_maps[map_id]
    end

    # -> [width, height] of +map_id+ | nil.
    def dims(map_id)
      m = @maps[map_id]
      m && m[:width].is_a?(Integer) && m[:height].is_a?(Integer) ? [m[:width], m[:height]] : nil
    end

    # --- warps (Layer B/C transfer legality) -----------------------------------
    # Does a warp on +from_map+ land on (+to_map+, x, y), or within +reach+ tiles of
    # it? Used to decide a cross-map move is a legal known teleport.
    def warp_dest?(from_map, to_map, x, y, reach: 0)
      list = @warps_by_map[from_map]
      return false unless list

      list.any? do |w|
        w["dest_map"] == to_map && (w["dest_x"] - x).abs <= reach && (w["dest_y"] - y).abs <= reach
      end
    end

    # Is (x, y) the tile of a warp event on +map+ (a door, stairs)? The player steps
    # onto it to trigger the warp, even where the tile under the event is a wall.
    def warp_src?(map_id, x, y)
      (@warps_by_map[map_id] || []).any? { |w| w["src_x"] == x && w["src_y"] == y }
    end

    def warps_on(map_id)
      @warps_by_map[map_id] || []
    end

    # --- spawns / connections / encounters -------------------------------------
    def heal(map_id); @heal[map_id]; end          # [map,x,y] | nil
    def home;  @home;  end                         # [map,x,y,dir] | nil
    def start; @start; end                         # [map,x,y] | nil
    def connections; @connections; end             # raw [m1,x1,y1,m2,x2,y2] arrays
    def encounters(map_id); @encounters[map_id]; end

    # The set of every species (String) that appears in ANY map's wild encounter table,
    # across all versions/types. Used by D5 to tell a fabricated wild-table mon (a
    # "client"-origin Pidgey) from a legitimate gift. Computed once, frozen.
    # The build-time switch/variable classification (v3 exports). nil = no manifest,
    # which the whole design reads as "everything is local" — the pre-sovereignty
    # behaviour, never an error. Nothing consumes this yet (step 2 ships the data).
    def flag_manifest
      @flag_manifest
    end

    # Item authority E1b: { "events" => [{ "map", "event" | "common_event", "calls",
    # "items", "unbounded" }], "berry_plants" => bool, "mining" => bool } | nil.
    def item_sources
      @item_sources
    end

    # Money authority M0: { "events" => [{ "map", "event" | "common_event", "calls",
    # "fields", "amounts", "computed" }] } | nil - every way an event raises money, coins
    # or battle points without a request the server answers.
    def money_sources
      @money_sources
    end

    # Every object of +kind+ ("item", "gift", "prize", "mart", "bp_shop") on every map.
    # -> [[map_id, object], ...]
    def objects_of(kind)
      @by_tile.filter_map { |(map, _x, _y), o| [map, o] if o["kind"] == kind }
    end

    def flag_tier(kind, id)
      m = @flag_manifest
      return "local" unless m

      section = m[kind.to_s]
      entry = section.is_a?(Hash) ? section[id.to_s] : nil
      entry.is_a?(Hash) ? (entry["tier"] || "local") : "local"
    end

    def wild_species
      @wild_species ||= begin
        set = {}
        @encounters.each_value do |versions|
          next unless versions.is_a?(Hash)

          versions.each_value do |types|
            next unless types.is_a?(Hash)

            types.each_value do |t|
              slots = t.is_a?(Hash) ? t["slots"] : nil
              next unless slots.is_a?(Array)

              slots.each { |s| set[s[1].to_s] = true if s.is_a?(Array) && s[1] }
            end
          end
        end
        set.keys.freeze
      end
    end

    # A tile the player can legally be teleported TO without a warp event: the
    # new-game start, the global home (whiteout fallback), or any map's heal
    # destination (Pokémon Center / Fly-heal return), or within +reach+ tiles of one.
    # Layer B transfer whitelist.
    def spawn_tile?(map, x, y, reach: 0)
      near = ->(d) { d && d[0] == map && (d[1] - x).abs <= reach && (d[2] - y).abs <= reach }
      near.call(@start) || near.call(@home) || @heal.each_value.any? { |d| near.call(d) }
    end

    # Is event +event_id+ on +map_id+ a prize table (several rewards, one picked: the
    # Game Corner lottery)? It pays out again and again by design.
    def prize_event?(map_id, event_id)
      o = @gifts[[map_id, event_id]]
      !o.nil? && o["kind"] == "prize"
    end

    # The export's record of an event that gives items (pbReceiveItem): kind "gift"
    # (one literal item) or "prize" (several). Newer exports add "once" (a single
    # payout, after which the event turns to another page), "dynamic" (a call whose
    # item is computed, so the literal list is not the whole story) and "quantities"
    # (item => largest literal quantity). -> frozen Hash | nil.
    def gift_object(map_id, event_id)
      @gifts[[map_id, event_id]]
    end

    # The export's record of a shop clerk: kind "mart" or "bp_shop", the items any of its
    # stock lists names, the prices the event sets, and "dynamic" when a list is computed.
    # -> frozen Hash | nil.
    def shop_object(map_id, event_id)
      @shops[[map_id, event_id]]
    end

    # --- trainers (Layer D D4 rewards) --------------------------------------------
    # Does this export say where trainer battles start? A pre-D4 export does not.
    def trainers_known?
      !@trainers_by_map.empty?
    end

    # Does a battle against this trainer start on +map_id+?
    def trainer_on_map?(map_id, type, name, version)
      (@trainers_by_map[map_id] || []).include?([type.to_s, name.to_s, version.to_i])
    end

    # Money authority M1a: the event of +map_id+ that starts a battle against this
    # trainer. -> { "rematch" => bool, "repeatable" => bool, "page" => the event page's
    # index, "no_money" => bool (the battle rules say it pays nothing),
    # "versions" => [the contact's versions here] } | nil
    def trainer_place(map_id, event_id, type, name, version)
      places = (@trainer_places[map_id] || {})[event_id.to_i] || []
      hit = places.find { |t| t[0] == type.to_s && t[1] == name.to_s && t[2] == version.to_i }
      return nil unless hit

      versions = places.select { |t| t[0] == hit[0] && t[1] == hit[1] && t[3] }.map { |t| t[2] }.sort
      { "rematch" => hit[3], "repeatable" => hit[4], "page" => hit[5], "no_money" => hit[6], "calls" => hit[7],
        "versions" => versions }
    end

    # Trainer proof P4: does a battle at this placement face this trainer alone? No other
    # trainer of the event shares a battle call naming it (a double battle's pair does). A
    # placement without calls (a phone rematch, an older export) is taken as alone.
    def trainer_alone?(map_id, event_id, type, name, version)
      places = (@trainer_places[map_id] || {})[event_id.to_i] || []
      hit = places.find { |t| t[0] == type.to_s && t[1] == name.to_s && t[2] == version.to_i }
      return false unless hit
      return true unless hit[7]

      places.none? { |t| !t.equal?(hit) && t[7] && !(t[7] & hit[7]).empty? }
    end

    # -> [[map, event, type, name, version], ...]: the placements that share a battle.
    def trainers_not_alone
      @trainer_places.sort.flat_map do |map_id, events|
        events.sort.flat_map do |event_id, list|
          list.reject { |t| trainer_alone?(map_id, event_id, *t[0, 3]) }.map { |t| [map_id, event_id, *t[0, 3]] }
        end
      end
    end

    # Does the export say which trainers share a battle (the calls naming each)?
    def battle_calls_known?
      @trainer_places.any? { |_, events| events.any? { |_, list| list.any? { |t| t[7] } } }
    end

    # Does any placement battle a phone rematch?
    def rematches_placed?
      @trainer_places.any? { |_, events| events.any? { |_, list| list.any? { |t| t[3] } } }
    end

    # Badge authority B0: does the export say what gives each badge?
    def badge_marks?
      !@badge_sources.nil?
    end

    # -> the sources of +badge+: [{ map:, event:, page:, trainers: [[type, name, version]] | nil }
    # | { common_event: }] - a source with trainers is their battle's win; one without is no
    # battle's. [] when nothing the export read gives it (nil: not exported).
    def badge_sources(badge)
      return nil unless @badge_sources

      @badge_sources.fetch(badge.to_i, [])
    end

    # The badge sets the export could not read (a computed index): [{ where..., script: }].
    attr_reader :badge_unknown

    # Money authority: the versions of +type+ / +name+ the game registers as a partner
    # trainer (pbRegisterPartner), whose party may hold an Amulet Coin. nil when the export
    # cannot say: from before it, or a partner computed at runtime.
    def partner_versions(type, name)
      return nil unless @partners

      @partners.select { |t, n, _| t == type.to_s && n == name.to_s }.map { |_, _, v| v }
    end

    # The placements whose battle the game lets be fought again outside the phone: the
    # win turns on nothing a later page waits for (Champion Blue's temporary switch), or
    # only under a further condition. nil when the export predates the mark.
    # -> [[map, event, type, name, version], ...]
    def repeatable_trainers
      return nil unless @trainer_marks

      @trainer_places.sort.flat_map do |map_id, events|
        events.sort.flat_map { |event_id, list| list.select { |t| t[4] }.map { |t| [map_id, event_id, *t[0, 3]] } }
      end
    end

    # Coarse: are these two maps joined by ANY edge connection? Used to accept an
    # edge-cross transfer without (yet) modelling the exact seam geometry.
    def connected?(map_a, map_b)
      @connections.any? do |c|
        (c[0] == map_a && c[3] == map_b) || (c[0] == map_b && c[3] == map_a)
      end
    end

    def summary
      return "absent (audit no-op — run the in-game exporter)" unless @loaded

      "#{@maps.size} maps, #{@by_tile.size} objects, #{@passable.size} passgrids, " \
        "#{@ledges.values.sum(&:size)} ledges, #{@water.size} water grids, #{@dive_maps.size} dive maps, " \
        "#{@warps_by_map.values.sum(&:size)} warps, " \
        "#{@connections.size} connections (schema v#{SCHEMA_VERSION})"
    end

    private

    def load!(path, expected_version)
      unless File.file?(path)
        @log.call("world: #{path} absent — Layer A/B audit runs in no-op mode until the in-game exporter is run")
        return
      end

      doc =
        begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise "world data #{path} is not valid JSON: #{e.message}"
        end

      accepted = expected_version.is_a?(Array) ? expected_version : [expected_version]
      unless doc.is_a?(Hash) && accepted.include?(doc["schema_version"])
        got = doc.is_a?(Hash) ? doc["schema_version"].inspect : "missing"
        raise "world data #{path} schema_version #{got} not in #{accepted.inspect} " \
              "(regenerate via the in-game 'PEMK: Export World' action)"
      end

      maps = doc["maps"]
      raise "world data #{path} 'maps' is not an object" unless maps.is_a?(Hash)

      maps.each { |map_key, m| load_map(path, map_key, m) }
      # The flag manifest (v3+). Absent = no classification = everything local, which
      # is exactly the pre-sovereignty behaviour. Frozen; nothing reads it yet (step 2
      # ships the data, step 3 consumes it).
      @flag_manifest = doc["flags"].is_a?(Hash) ? deep_freeze(doc["flags"]) : nil
      # Item authority E1b: the events that produce items no request names. Absent =
      # an export from before it: the server cannot tell those items apart.
      @item_sources = doc["item_sources"].is_a?(Hash) ? deep_freeze(doc["item_sources"]) : nil
      # Money authority M0: the events that raise a balance by themselves. Absent = an
      # export from before it.
      @money_sources = doc["money_sources"].is_a?(Hash) ? deep_freeze(doc["money_sources"]) : nil
      # ... and whether its trainer placements say which battles can be fought again.
      @trainer_marks = doc["trainer_marks"] == true
      # ... and whether its maps mark water.
      @water_marks = doc["water_marks"] == true
      @partners = load_partners(doc["partners"])
      @badge_sources, @badge_unknown = load_badge_sources(doc["badge_sources"])
      @connections = freeze_connections(doc["connections"])
      @home  = coord_array(doc["home"], 4) || coord_array(doc["home"], 3)
      @start = coord_array(doc["start"], 3)

      freeze_all
      @loaded = true
      @log.call("world: loaded #{summary} from #{path}")
    end

    def load_map(path, map_key, m)
      map_id = begin; Integer(map_key); rescue ArgumentError, TypeError; nil; end
      return unless map_id && m.is_a?(Hash)

      width  = m["width"]
      height = m["height"]

      load_objects(map_id, m["objects"])
      load_passability(path, map_id, m["passability"], width, height)
      load_ledges(map_id, m["ledges"])
      load_water(path, map_id, m["water"], width, height)
      @dive_maps[map_id] = m["dive_map"] if m["dive_map"].is_a?(Integer) && m["dive_map"].positive?
      @surface_maps[map_id] = m["surface_map"] if m["surface_map"].is_a?(Integer) && m["surface_map"].positive?
      load_warps(map_id, m["warps"])
      h = coord_array(m["heal"], 3)
      @heal[map_id] = h if h
      @encounters[map_id] = m["encounters"] if m["encounters"].is_a?(Hash)
      load_trainers(map_id, m["trainers"])

      @maps[map_id] = { name: m["name"], width: width, height: height,
                        count: (m["objects"].is_a?(Array) ? m["objects"].size : 0) }.freeze
    end

    def load_objects(map_id, objects)
      return unless objects.is_a?(Array)

      objects.each do |obj|
        next unless obj.is_a?(Hash)

        x = obj["x"]; y = obj["y"]
        next unless x.is_a?(Integer) && y.is_a?(Integer)

        key = [map_id, x, y]
        if @by_tile.key?(key)
          @log.call("world: duplicate object on tile (#{map_id},#{x},#{y}) — keeping first")
          next
        end
        @by_tile[key] = obj.freeze
        ev = obj["event_id"]
        @gifts[[map_id, ev]] = obj if %w[gift prize].include?(obj["kind"]) && ev.is_a?(Integer)
        next unless %w[mart bp_shop].include?(obj["kind"]) && ev.is_a?(Integer)

        @shops[[map_id, ev]] = obj
        if obj["prices_unread"]
          @log.call("world: the clerk on map #{map_id} (event #{ev}) computes a price the export cannot read " \
                    "- the server holds it to the catalogue's and its literal prices")
        end
      end
    end

    def load_passability(path, map_id, grid, width, height)
      return if grid.nil?

      unless grid.is_a?(Array) && width.is_a?(Integer) && height.is_a?(Integer) &&
             grid.length == height &&
             grid.all? { |r| r.is_a?(String) && r.length == width && r.match?(/\A[0-9a-f]*\z/) }
        raise "world data #{path} map #{map_id} passability is malformed " \
              "(need #{height} hex-nibble strings of #{width} chars; regenerate the export)"
      end

      @passable[map_id] = grid.map(&:freeze).freeze
    end

    def load_water(path, map_id, grid, width, height)
      return if grid.nil?

      unless grid.is_a?(Array) && width.is_a?(Integer) && height.is_a?(Integer) &&
             grid.length == height &&
             grid.all? { |r| r.is_a?(String) && r.length == width && r.match?(/\A[.wdx]*\z/) }
        raise "world data #{path} map #{map_id} water is malformed " \
              "(need #{height} strings of #{width} '.', 'w', 'd' or 'x'; regenerate the export)"
      end

      @water[map_id] = grid.map(&:freeze).freeze
    end

    def water_char(map_id, x, y)
      grid = @water[map_id]
      return nil unless grid && y >= 0 && y < grid.length

      row = grid[y]
      x >= 0 && x < row.length ? row[x] : nil
    end

    def load_ledges(map_id, ledges)
      return unless ledges.is_a?(Array)

      set = {}
      ledges.each do |t|
        next unless t.is_a?(Array) && t.length == 2 && t[0].is_a?(Integer) && t[1].is_a?(Integer)

        set[[t[0], t[1]]] = true
      end
      @ledges[map_id] = set.freeze unless set.empty?
    end

    # [{event_id, x, y, type, name, version}, ...] -> the trainers whose battles start here.
    def load_trainers(map_id, list)
      return unless list.is_a?(Array)

      ids = list.filter_map do |t|
        next unless t.is_a?(Hash) && t["type"] && t["name"]

        [t["type"].to_s, t["name"].to_s, t["version"].to_i].freeze
      end
      @trainers_by_map[map_id] = ids.uniq.freeze unless ids.empty?
      # M1a: by event, with the rematch and repeatable marks (an export before them has
      # neither).
      by_event = {}
      list.each do |t|
        next unless t.is_a?(Hash) && t["type"] && t["name"] && t["event_id"].is_a?(Integer)

        (by_event[t["event_id"]] ||= []) << [t["type"].to_s, t["name"].to_s, t["version"].to_i, t["rematch"] == true,
                                             t["repeatable"] == true, t["page"].is_a?(Integer) ? t["page"] : 0,
                                             t["no_money"] == true, call_list(t["calls"])].freeze
      end
      @trainer_places[map_id] = by_event.transform_values(&:freeze).freeze unless by_event.empty?
    end

    # A placement's battle calls ([Integer]), or nil when the export does not say.
    def call_list(value)
      return nil unless value.is_a?(Array) && value.all? { |c| c.is_a?(Integer) }

      value.uniq.freeze
    end

    # { "list" => [[type, name, version], ...], "computed" => bool } -> the list, or nil
    # when a partner is computed at runtime (or the export predates the list).
    # -> [{ badge => [source, ...] } | nil, [unknown, ...]]
    def load_badge_sources(doc)
      return [nil, [].freeze] unless doc.is_a?(Hash) && doc["list"].is_a?(Array)

      by_badge = Hash.new { |h, k| h[k] = [] }
      doc["list"].each do |e|
        next unless e.is_a?(Hash) && e["badge"].is_a?(Integer) && e["badge"] >= 0

        source = if e["common_event"].is_a?(Integer)
                   { common_event: e["common_event"] }
                 elsif [e["map"], e["event"]].all? { |v| v.is_a?(Integer) }
                   trainers = Array(e["trainers"]).filter_map do |t|
                     [t[0].to_s, t[1].to_s, t[2]].freeze if t.is_a?(Array) && t.length == 3 && t[2].is_a?(Integer)
                   end
                   { map: e["map"], event: e["event"], page: e["page"].is_a?(Integer) ? e["page"] : 0,
                     trainers: trainers.empty? ? nil : trainers.freeze }
                 end
        by_badge[e["badge"]] << source.freeze if source
      end
      unknown = Array(doc["unknown"]).select { |u| u.is_a?(Hash) }.map { |u| deep_freeze(u) }
      [by_badge.transform_values(&:freeze).to_h.freeze, unknown.freeze]
    end

    def load_partners(doc)
      return nil unless doc.is_a?(Hash) && doc["computed"] != true && doc["list"].is_a?(Array)

      doc["list"].filter_map do |e|
        next unless e.is_a?(Array) && e.length == 3 && e[2].is_a?(Integer)

        [e[0].to_s, e[1].to_s, e[2]].freeze
      end.uniq.freeze
    end

    def load_warps(map_id, warps)
      return unless warps.is_a?(Array)

      valid = warps.select do |w|
        w.is_a?(Hash) && w["dest_map"].is_a?(Integer) &&
          w["dest_x"].is_a?(Integer) && w["dest_y"].is_a?(Integer)
      end
      @warps_by_map[map_id] = valid.map(&:freeze).freeze unless valid.empty?
    end

    # A JSON array of exactly +len+ integers, else nil (tolerant).
    def coord_array(v, len)
      return nil unless v.is_a?(Array) && v.length == len && v.all? { |n| n.is_a?(Integer) }

      v
    end

    # Recursively freeze a parsed JSON subtree (the manifest is read-only at runtime).
    def deep_freeze(obj)
      case obj
      when Hash  then obj.each_value { |v| deep_freeze(v) }.freeze
      when Array then obj.each { |v| deep_freeze(v) }.freeze
      else obj.freeze
      end
    end

    def freeze_connections(conns)
      return [].freeze unless conns.is_a?(Array)

      # Records are [map1, edge1, off1, map2, edge2, off2]; edge1/edge2 may be letter
      # Strings. Only [0]/[3] (the map ids) are read by connected?, so require just
      # those to be Integers — matching the exporter's load_connections filter.
      conns.select { |c| c.is_a?(Array) && c.length >= 6 && c[0].is_a?(Integer) && c[3].is_a?(Integer) }
           .map { |c| c[0, 6].freeze }.freeze
    end

    def freeze_all
      @by_tile.freeze
      @maps.freeze
      @passable.freeze
      @ledges.freeze
      @water.freeze
      @dive_maps.freeze
      @surface_maps.freeze
      @warps_by_map.freeze
      @heal.freeze
      @encounters.freeze
      @trainers_by_map.freeze
      @trainer_places.freeze
      @gifts.freeze
      @shops.freeze
    end
  end
end
