#===============================================================================
# PEMK :: WorldExport  (client side — M4 Layer A/B, DEV BUILD TOOL)
#-------------------------------------------------------------------------------
# Flattens the game's static world to a plain-JSON file the dedicated server reads
# as its read-only world model (server/lib/pemk/world_data.rb). Runs IN-ENGINE
# (mkxp-z) because only here are the RMXP map/tileset/event classes loaded — the
# server must NEVER Marshal.load a .rxdata map (RCE surface). One diffable artifact,
# server/data/world.json, committed to the repo; regenerate after editing maps.
#
# Schema v2 exports, per map: item OBJECTS (Layer A/C), a PASSABILITY grid
# (Layer B no-clip), WARP endpoints (Layer B/C), the HEAL point, and ENCOUNTERS
# (Layer D); and top-level: map CONNECTIONS (edge stitching), HOME and START
# (respawn/genesis whitelist). Passability is H hex-nibble row strings (W chars),
# nibble = the ground tile's RMXP passage bits, 0x0f ('f') == fully blocked.
#
# Triggered from the F9 debug menu ("PEMK: Export World"), so it never ships to
# players and needs no core-script edit. JSON is hand-rolled (mkxp-z has no
# guaranteed json stdlib; the client wire codec is custom for the same reason).
#===============================================================================

module PEMK
  module WorldExport
    module_function

    SCHEMA_VERSION = 2
    OUT_PATH       = "server/data/world.json"   # relative to the game root (cwd)

    # -> counts hash. Raises on a write failure (surfaced by the menu).
    def run
      mapinfos = load_data("Data/MapInfos.rxdata")
      maps  = {}
      counts = { :objects => 0, :warps => 0, :passability => 0, :ledges => 0, :heal => 0, :encounters => 0 }

      mapinfos.keys.sort.each do |map_id|
        map = (load_data(sprintf("Data/Map%03d.rxdata", map_id)) rescue nil)
        next unless map && map.respond_to?(:events) && map.events

        objects = []
        warps   = []
        map.events.each_value do |event|
          o = classify_event(event); objects << o if o
          collect_warps(event).each { |w| warps << w }
        end
        passability = map_passability(map)
        ledges      = map_ledges(map)
        heal        = map_heal(map_id)
        enc         = map_encounters(map_id)

        # Emit a map only if it carries at least one useful fact.
        next if objects.empty? && warps.empty? && passability.nil? && heal.nil? && enc.nil? && ledges.empty?

        entry = { :name => map_name(mapinfos, map_id), :width => map.width, :height => map.height,
                  :objects => objects }
        entry[:warps]       = warps       unless warps.empty?
        entry[:passability] = passability if passability
        entry[:ledges]      = ledges      unless ledges.empty?
        entry[:heal]        = heal        if heal
        entry[:encounters]  = enc         if enc
        maps[map_id.to_s] = entry

        counts[:objects]    += objects.size
        counts[:warps]      += warps.size
        counts[:passability] += 1 if passability
        counts[:ledges]     += ledges.size
        counts[:heal]       += 1 if heal
        counts[:encounters] += 1 if enc
      end

      doc = { :schema_version => SCHEMA_VERSION, :generated_at => stamp, :maps => maps }
      conns = load_connections
      doc[:connections] = conns unless conns.empty?
      home = global_home
      doc[:home] = home if home
      st = start_point
      doc[:start] = st if st

      File.open(File.expand_path(OUT_PATH), "w") { |f| f.write(pretty(doc, 0) + "\n") }
      counts.merge(:maps => maps.size, :connections => conns.size)
    end

    # Run + report to the player (used by the debug-menu effect).
    def run_with_feedback
      c = run
      pbMessage(_INTL("World export OK ->\nserver/data/world.json\n\n{1} maps, {2} objects, {3} warps, {4} passgrids, {5} ledge tiles, {6} connections.\n\nCommit it so the server ships a world model.",
                      c[:maps], c[:objects], c[:warps], c[:passability], c[:ledges], c[:connections]))
    rescue => e
      PEMK.log("world: export failed #{e.class}: #{e.message}")
      pbMessage(_INTL("World export FAILED:\n{1}: {2}", e.class.to_s, e.message))
    end

    def map_name(mapinfos, map_id)
      info = mapinfos[map_id]
      info.respond_to?(:name) ? info.name.to_s : nil
    end

    # === objects (item balls) — Layer A/C ======================================

    # -> object hash | nil. First LITERAL item on the event's tile wins.
    # Only a literal symbol (pbItemBall(:POTION)) is recorded — a dynamic argument
    # would export a bogus id and turn every real pickup into a false mismatch.
    def classify_event(event)
      return nil unless event && event.respond_to?(:pages) && event.pages

      script = event_script(event)
      return nil unless script

      if (m = script.match(/pbItemBall\(\s*:([A-Za-z0-9_]+)/))
        { :kind => "item", :item => m[1], :x => event.x, :y => event.y, :event_id => event.id }
      elsif (m = script.match(/pbReceiveItem\(\s*:([A-Za-z0-9_]+)/))
        { :kind => "gift", :item => m[1], :x => event.x, :y => event.y, :event_id => event.id }
      end
    rescue
      nil
    end

    # Concatenate the searchable script text across all pages. RMXP stores item
    # balls as a CONDITIONAL BRANCH (code 111, subtype 12, text in params[1]), not a
    # plain Script command (code 355/655, text in params[0]) — read both.
    def event_script(event)
      parts = []
      event.pages.each do |page|
        next unless page && page.list

        page.list.each do |cmd|
          next unless cmd.respond_to?(:code)

          params = (cmd.respond_to?(:parameters) ? cmd.parameters : nil)
          next unless params

          case cmd.code
          when 355, 655
            parts << params[0].to_s if params[0]
          when 111
            parts << params[1].to_s if params[0] == 12 && params[1]
          end
        end
      end
      parts.empty? ? nil : parts.join("\n")
    end

    # === warps (Transfer Player, code 201) — Layer B/C =========================

    # -> Array of warp hashes, one per DISTINCT direct-appointment (p[0]==0) code-201
    # destination across the event's pages. Variable-mode transfers are skipped (a
    # $game_variables index is not a static dest); an event with several
    # switch-guarded pages that transfer to different maps exports each destination.
    def collect_warps(event)
      return [] unless event && event.respond_to?(:pages) && event.pages

      seen = {}
      out  = []
      event.pages.each do |page|
        next unless page && page.list

        page.list.each do |cmd|
          next unless cmd.respond_to?(:code) && cmd.code == 201

          p = cmd.parameters
          next unless p && p[0] == 0

          key = [p[1], p[2], p[3]]
          next if seen[key]

          seen[key] = true
          out << { :src_x => event.x, :src_y => event.y,
                   :dest_map => p[1], :dest_x => p[2], :dest_y => p[3],
                   :dir => p[4], :event_id => event.id }
        end
      end
      out
    rescue
      []
    end

    # === passability — Layer B no-clip =========================================

    # -> Array of H hex-nibble row strings (W chars) | nil. Reuses the load/iterate
    # skeleton of getPassabilityMinimap but the ENGINE-FAITHFUL rule (priority-0
    # ground tile's passage bits; 0x0f == blocked), not its passage<15 helper.
    def map_passability(map)
      return nil unless $data_tilesets

      tileset = $data_tilesets[map.tileset_id]
      return nil unless tileset && tileset.respond_to?(:passages)

      passages     = tileset.passages
      priorities   = tileset.priorities
      terrain_tags = tileset.terrain_tags
      data = map.data
      w = map.width
      h = map.height

      rows = []
      h.times do |y|
        row = +""
        w.times { |x| row << passability_nibble(data, x, y, passages, priorities, terrain_tags).to_s(16) }
        rows << row
      end
      rows
    rescue
      nil
    end

    # -> Array of [x,y] tiles whose effective terrain is a LEDGE (a one-way hop tile).
    # Lets Layer B accept a 2-tile ledge jump instead of flagging it as a teleport.
    def map_ledges(map)
      return [] unless $data_tilesets

      tileset = $data_tilesets[map.tileset_id]
      return [] unless tileset && tileset.respond_to?(:terrain_tags)

      terrain_tags = tileset.terrain_tags
      data = map.data
      out = []
      map.height.times do |y|
        map.width.times { |x| out << [x, y] if ledge_tile?(data, x, y, terrain_tags) }
      end
      out
    rescue
      []
    end

    # Resolve a tile's terrain tag WITHOUT GameData::TerrainTag.try_get. Under this
    # mkxp-z build try_get raises on an Integer arg (its `validate ... is_a?(Integer)`
    # misfires on a Table-returned int), so we look up DATA directly — DATA is keyed
    # by BOTH symbol and id_number, and a Hash lookup uses eql?/hash (which work),
    # not is_a?. -> TerrainTag | nil.
    def terrain_of(terrain_tags, tid)
      ttid = terrain_tags[tid]
      return nil if ttid.nil?

      # DATA[ttid] uses eql?/hash (reliable), NOT is_a? (the misfiring op) — so pass
      # the raw value straight to the Hash lookup, no is_a? gate.
      (GameData::TerrainTag::DATA[ttid] rescue nil)
    rescue
      nil
    end

    # The effective terrain (first non-:None going [2,1,0], like Game_Map#terrain_tag)
    # is a ledge.
    def ledge_tile?(data, x, y, terrain_tags)
      [2, 1, 0].each do |z|
        tid = data[x, y, z]
        next if tid.nil? || tid == 0

        tt = terrain_of(terrain_tags, tid)
        next unless tt
        next if tt.id_number == 0   # :None -> keep looking at lower layers

        return tt.ledge ? true : false
      end
      false
    rescue
      false
    end

    def passability_nibble(data, x, y, passages, priorities, terrain_tags)
      nib = 0
      [2, 1, 0].each do |z|
        tid = data[x, y, z]
        next if tid.nil? || tid == 0
        next if terrain_ignores_passability?(terrain_tags, tid)

        p = passages[tid] & 0x0f
        if p == 0x0f
          nib = 0x0f
          break
        end
        if priorities[tid] == 0
          nib = p
          break
        end
      end
      nib
    end

    def terrain_ignores_passability?(terrain_tags, tid)
      tt = terrain_of(terrain_tags, tid)
      tt ? tt.ignore_passability : false
    rescue
      false
    end

    # === spawns / connections / encounters =====================================

    def map_heal(map_id)
      md = (GameData::MapMetadata.try_get(map_id) rescue nil)
      d = md && md.teleport_destination
      (d.is_a?(Array) && d.length >= 3) ? [d[0], d[1], d[2]] : nil
    rescue
      nil
    end

    def global_home
      md = (GameData::Metadata.get rescue nil)
      h = md && md.home
      (h.is_a?(Array) && h.length >= 3) ? h[0, 4] : nil   # [map,x,y,(dir)]
    rescue
      nil
    end

    def start_point
      return nil unless $data_system

      m = $data_system.start_map_id
      return nil unless m.is_a?(Integer) && m > 0

      [m, $data_system.start_x, $data_system.start_y]
    rescue
      nil
    end

    # Raw compiled connection records: 6-int arrays [m1,x1,y1,m2,x2,y2]. The server
    # interprets the edge geometry (Layer B); we just carry them faithfully.
    def load_connections
      raw = (load_data("Data/map_connections.dat") rescue nil)
      return [] unless raw.is_a?(Array)

      out = []
      raw.each do |conn|
        next unless conn.is_a?(Array) && conn.length >= 6

        # Standard records are [map1, edge1, off1, map2, edge2, off2] where edge1/edge2
        # are letter Strings ("N"/"S"/"E"/"W"); only [0] and [3] are the map ids the
        # server keys on. Carry the record whenever both map ids are Integers.
        six = conn[0, 6]
        out << six if six[0].is_a?(Integer) && six[3].is_a?(Integer)
      end
      out
    rescue
      []
    end

    def map_encounters(map_id)
      return nil unless defined?(GameData::Encounter)

      result = {}
      GameData::Encounter.each do |enc|
        next unless enc.map == map_id

        types = {}
        (enc.types || {}).each do |type, slots|
          sc = enc.step_chances && enc.step_chances[type]
          types[type.to_s] = { :step_chance => sc, :slots => slots }
        end
        result[enc.version.to_s] = types unless types.empty?
      end
      result.empty? ? nil : result
    rescue
      nil
    end

    def stamp
      Time.now.strftime("%Y-%m-%dT%H:%M:%S")
    rescue
      ""
    end

    # === dependency-free JSON writer (recursive pretty, diffable) ===============

    # Hashes expand one key per line; Arrays expand one element per line (each
    # element compact via jval). Valid JSON for any nesting our data uses.
    def pretty(obj, indent)
      pad  = "  " * indent
      pad2 = "  " * (indent + 1)
      case obj
      when Hash
        return "{}" if obj.empty?

        body = obj.map { |k, v| "#{pad2}#{jstr(k.to_s)}: #{pretty(v, indent + 1)}" }.join(",\n")
        "{\n#{body}\n#{pad}}"
      when Array
        return "[]" if obj.empty?

        body = obj.map { |v| "#{pad2}#{jval(v)}" }.join(",\n")
        "[\n#{body}\n#{pad}]"
      else
        jval(obj)
      end
    end

    # Compact one-line JSON for a value (used for leaf arrays/objects + scalars).
    def jval(v)
      case v
      when Hash    then "{" + v.map { |k, x| "#{jstr(k.to_s)}: #{jval(x)}" }.join(", ") + "}"
      when Array   then "[" + v.map { |x| jval(x) }.join(", ") + "]"
      when Integer then v.to_s
      when Float   then v.to_s
      when true    then "true"
      when false   then "false"
      when nil     then "null"
      when Symbol  then jstr(v.to_s)
      else              jstr(v.to_s)
      end
    end

    def jstr(s)
      out = +"\""
      s.to_s.each_char do |c|
        case c
        when "\"" then out << "\\\""
        when "\\" then out << "\\\\"
        when "\n" then out << "\\n"
        when "\r" then out << "\\r"
        when "\t" then out << "\\t"
        else
          out << (c.ord < 0x20 ? format("\\u%04x", c.ord) : c)
        end
      end
      out << "\""
      out
    end
  end
end

# --- register the dev-only debug-menu action (only visible in debug mode) --------
if defined?(MenuHandlers)
  MenuHandlers.add(:debug_menu, :pemk_export_world, {
    "name"        => _INTL("PEMK: Export World (Layer A/B)"),
    "parent"      => :main,
    "description" => _INTL("Write server/data/world.json (objects, passability, warps, spawns, encounters) for the server-side world model."),
    "always_show" => false,
    "effect"      => proc {
      PEMK::WorldExport.run_with_feedback
      next
    }
  })
end
