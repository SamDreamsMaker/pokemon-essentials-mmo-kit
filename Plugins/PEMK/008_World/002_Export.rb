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
# WATER rows mark where a surfer may be ('w'), where Dive also goes down or comes up
# ('d'), and deep water under a rock ('x': a diver comes up there, no surfer goes);
# DIVE_MAP is the map below, SURFACE_MAP (on a map below) the one a diver comes up to.
# The passability grid counts water as walls.
#
# Triggered from the F9 debug menu ("PEMK: Export World"), so it never ships to
# players and needs no core-script edit. JSON is hand-rolled (mkxp-z has no
# guaranteed json stdlib; the client wire codec is custom for the same reason).
#===============================================================================

module PEMK
  module WorldExport
    module_function

    SCHEMA_VERSION = 3   # v3 adds the optional :flags manifest (v2 readers ignore it)
    OUT_PATH       = "server/data/world.json"   # relative to the game root (cwd)

    # -> counts hash. Raises on a write failure (surfaced by the menu).
    def run
      mapinfos = load_data("Data/MapInfos.rxdata")
      maps  = {}
      counts = { :objects => 0, :warps => 0, :passability => 0, :ledges => 0, :heal => 0, :encounters => 0,
                 :trainers => 0, :water => 0 }

      all_events = []   # [map_id, event] for the item sources (item authority E1b)
      @common_events = nil      # read again: the dev may have edited them since the last export
      @trainer_versions = nil   # ... and the trainers
      @rematches_possible = nil # ... and whether the phone can ever offer a rematch
      mapinfos.keys.sort.each do |map_id|
        map = (load_data(sprintf("Data/Map%03d.rxdata", map_id)) rescue nil)
        next unless map && map.respond_to?(:events) && map.events

        objects  = []
        warps    = []
        trainers = []
        map.events.each_value do |event|
          all_events << [map_id, event]
          o = classify_event(event); objects << unread_prices(map_id, o) if o
          collect_warps(event).each { |w| warps << w }
          fought = battle_marks(event)   # money authority M3: once? which page? paying nothing?
          collect_trainers(event).each do |type, name, version, rematch|
            t = { :event_id => event.id, :x => event.x, :y => event.y, :type => type, :name => name,
                  :version => version }
            t[:rematch] = true if rematch
            once, page, free, calls = fought[[type, name, version]]
            t[:repeatable] = true unless rematch || once
            t[:page] = page if page && page > 0
            t[:no_money] = true if free
            t[:calls] = calls if calls   # the battle calls naming it: one battle's trainers share one
            trainers << t
          end
        end
        passability = map_passability(map)
        ledges      = map_ledges(map)
        water       = map_water(map)
        dive        = dive_map_of(map_id)
        surface     = surface_map_of(map_id)
        heal        = map_heal(map_id)
        enc         = map_encounters(map_id)

        # Emit a map only if it carries at least one useful fact.
        next if objects.empty? && warps.empty? && passability.nil? && heal.nil? && enc.nil? && ledges.empty? &&
                trainers.empty? && water.nil? && dive.nil? && surface.nil?

        entry = { :name => map_name(mapinfos, map_id), :width => map.width, :height => map.height,
                  :objects => objects }
        entry[:warps]       = warps       unless warps.empty?
        entry[:passability] = passability if passability
        entry[:ledges]      = ledges      unless ledges.empty?
        entry[:water]       = water       if water
        entry[:dive_map]    = dive        if dive
        entry[:surface_map] = surface     if surface
        entry[:heal]        = heal        if heal
        entry[:encounters]  = enc         if enc
        entry[:trainers]    = trainers    unless trainers.empty?
        maps[map_id.to_s] = entry

        counts[:objects]    += objects.size
        counts[:warps]      += warps.size
        counts[:passability] += 1 if passability
        counts[:ledges]     += ledges.size
        counts[:water]      += 1 if water
        counts[:heal]       += 1 if heal
        counts[:encounters] += 1 if enc
        counts[:trainers]   += trainers.size
      end

      doc = { :schema_version => SCHEMA_VERSION, :generated_at => stamp, :maps => maps }
      # Step 2 of sovereign variables: classify the dev's own switch/variable usage.
      # Optional by construction — a nil section just means "nothing to say", and the
      # server treats a missing manifest as all-local (today's behaviour).
      flags = (PEMK::FlagManifest.build rescue nil)
      doc[:flags] = flags if flags
      conns = load_connections
      doc[:connections] = conns unless conns.empty?
      home = global_home
      doc[:home] = home if home
      st = start_point
      doc[:start] = st if st
      sources = (item_sources(all_events) rescue nil)
      doc[:item_sources] = sources if sources
      money = (money_sources(all_events) rescue nil)
      doc[:money_sources] = money if money
      doc[:trainer_marks] = true   # the placements say which battles can be fought again
      doc[:water_marks] = true     # the maps say where a surfer may be (none: no water there)
      partners = (partner_registrations(all_events) rescue nil)
      doc[:partners] = partners if partners
      badges = (badge_sources(all_events) rescue nil)   # badge authority B0: what gives each badge
      doc[:badge_sources] = badges if badges
      keys = (field_keys(all_events) rescue nil)        # mode keys: what Surf and Dive need
      doc[:field_keys] = keys if keys

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

      if (m = script.match(/pbItemBall\(\s*:([A-Za-z0-9_]+)\s*(?:,\s*(\d+)\s*)?\)/) ||
              script.match(/pbItemBall\(\s*:([A-Za-z0-9_]+)/))
        { :kind => "item", :item => m[1], :quantity => (m[2] || 1).to_i,
          :x => event.x, :y => event.y, :event_id => event.id }
      elsif (shop = shop_facts(event, script))
        shop.merge(:x => event.x, :y => event.y, :event_id => event.id)
      elsif (items = script.scan(/pbReceiveItem\(\s*:([A-Za-z0-9_]+)/).flatten).any?
        # More than one branch means the event picks a reward, so it is a PRIZE, not a
        # one-shot gift. The Game Corner lottery is the case: five tiers, and taking the
        # first match labelled the whole daily event as a Master Ball story gift - which
        # sent a review chasing a re-farm that did not exist. Ship every tier.
        kind = items.uniq.length > 1 ? "prize" : "gift"
        { :kind => kind, :item => items.first, :items => items.uniq,
          :x => event.x, :y => event.y, :event_id => event.id }.merge(gift_facts(event, script))
      end
    rescue
      nil
    end

    # Item authority: a clerk's stock. Every literal list its Mart or Battle Point shop
    # call is given, merged (badge branches each hand the Mart a longer list), and the
    # prices its calls may use (clerk_prices). A computed list makes the stock unknown.
    # -> { :kind => "mart" | "bp_shop", :items =>, :prices =>, :price_options =>,
    #      :sell_options =>, :dynamic => } | nil
    def shop_facts(event, script)
      kind = if script.include?("pbPokemonMart(") then "mart"
             elsif script.include?("pbBattlePointShop(") then "bp_shop"
             end
      return nil unless kind

      call = kind == "mart" ? "pbPokemonMart" : "pbBattlePointShop"
      items = []
      dynamic = false
      script.scan(/#{call}\(\s*(\[[^\]]*\]|[^,)\s]+)/m) do |(arg)|
        if arg.start_with?("[")
          items.concat(arg.scan(/:([A-Za-z0-9_]+)/).flatten)
        else
          dynamic = true
        end
      end
      prices = clerk_prices(event, kind)
      facts = { :kind => kind, :items => items.uniq, :prices => literal_prices(script),
                :price_options => prices[:buy], :dynamic => dynamic }
      if kind == "mart"
        facts[:sell_options] = prices[:sell]
        facts[:sells] = false unless prices[:sells]
      end
      facts[:unread] = prices[:unread] unless prices[:unread].empty?
      facts
    rescue
      nil
    end

    # A clerk whose event computes a price: the server cannot check that price, so the log
    # names the call and the export flags the clerk for the server's own warning.
    def unread_prices(map_id, obj)
      calls = obj.delete(:unread)
      return obj if calls.nil? || calls.empty?

      calls.each { |c| PEMK.log("world: map #{map_id} event #{obj[:event_id]} sets a price the export cannot read: #{c}") }
      obj.merge(:prices_unread => true)
    end

    # The last literal buy price the event sets for each item: what a server from before
    # :price_options checks against.
    def literal_prices(script)
      prices = {}
      script.scan(/setPrice\(\s*:([A-Za-z0-9_]+)\s*,\s*(\d+)/) do |item, price|
        prices[item] = price.to_i if price.to_i > 0
      end
      prices
    end

    # === a clerk's prices — item authority E3 ==================================

    # The engine keeps what setPrice / setSellPrice set until the next pbPokemonMart or
    # pbBattlePointShop, which uses it and forgets it. An event may set a price on one
    # branch only (the Lerucean stall's Saturday sale), so one clerk charges its own price
    # on one visit and the catalogue's on the next. This follows each page the way the
    # interpreter runs it (branches, choices, loops, labels, exits, common events) and
    # notes every price a Mart call may see; a script with Ruby control flow of its own may
    # run each of its calls, or not, or again.
    # -> { :buy => { item => [price | nil, ...] }, :sell => { item => [...] },
    #      :sells => whether a Mart call can buy anything back (its cantsell argument),
    #      :unread => the calls whose price the export cannot read (computed arguments) }
    # nil stands for the catalogue's price. Only the items some call sets a price for are
    # listed: every other item is at the catalogue's.
    def clerk_prices(event, kind)
      found  = {}
      unread = []
      event.pages.each { |page| flow_prices(page.list, {}, found, unread, 0) if page && page.list }
      marts = found.values.select { |_, k, _| k == kind }
      buys  = {}
      sells = {}
      marts.flat_map { |state, _, _| state.keys }.uniq.each do |item|
        marts.each do |state, _, can_sell|
          (state[item] || [[-1, -1]]).each do |buy, sell|
            (buys[item] ||= []) << (buy > 0 ? buy : nil)
            (sells[item] ||= []) << (sell >= 0 ? sell : nil) if can_sell
          end
        end
      end
      { :buy => price_options(buys), :sell => price_options(sells),
        :sells => marts.empty? || marts.any? { |_, _, can_sell| can_sell }, :unread => unread.uniq }
    end

    # item => its distinct prices, nil (the catalogue's) first; an item only ever at the
    # catalogue's is left out.
    def price_options(options)
      out = {}
      options.keys.sort.each do |item|
        list = options[item].uniq.sort_by { |p| p || -1 }
        out[item] = list unless list == [nil]
      end
      out
    end

    PRICE_CALL  = /(?<![A-Za-z0-9_])(setPrice|setSellPrice|pbPokemonMart|pbBattlePointShop)\s*\(/.freeze
    # Ruby that may skip or repeat a call: a script with any of it may run each call or not.
    SCRIPT_FLOW = /\b(?:if|unless|case|while|until|for|loop|rescue|return|next|break|redo|retry|and|or|not|begin|do|yield|each|times|upto|downto|step|map|select|reject|proc|lambda|def)\b|[?{]|&&|\|\||->/.freeze
    PRICE_DEPTH = 4        # common events calling common events, followed this deep
    PRICE_STEPS = 20_000   # an event's walk, bounded

    # Follows +list+ (a page, a common event) from +state+ (item => [[buy, sell], ...],
    # -1: not set, the engine's own marks) and joins the state at each Mart call it
    # reaches into +found+. -> the state the list ends with (nil: it never ends).
    def flow_prices(list, state, found, unread, depth)
      ins   = { 0 => state }
      out   = nil
      work  = [0]
      steps = 0
      until work.empty?
        if (steps += 1) > PRICE_STEPS
          unread << "an event too long to follow"
          return join_prices(out, {})
        end
        i = work.shift
        st = ins[i]
        if i >= list.size - 1   # the end of the list: the interpreter stops
          out = join_prices(out, st)
          next
        end
        succ, st = flow_step(list, i, st, found, unread, depth)
        if succ == :exit
          out = join_prices(out, st)
          next
        end
        succ.each do |j|
          nxt = join_prices(ins[j], st)
          next if nxt == ins[j]

          ins[j] = nxt
          work << j unless work.include?(j)
        end
      end
      out
    end

    # One command, as the interpreter runs it (004_Interpreter_Commands).
    # -> [the commands that may run next | :exit, the state after it]
    def flow_step(list, i, st, found, unread, depth)
      cmd = list[i]
      params = cmd.parameters || []
      case cmd.code
      when 111, 402, 403, 601, 602, 603   # a branch: into its body, or on to the next at its level
        [[i + 1, same_level(list, i)].compact, st]
      when 411                            # else: only reached when the branch was not taken
        [[i + 1], st]
      when 413                            # repeat above: back to the top of the loop
        j = (i - 1).downto(0).find { |k| list[k].indent == cmd.indent }
        [[j ? j + 1 : i + 1], st]
      when 113                            # break loop: past the end of the loop
        j = ((i + 1)...(list.size - 1)).find { |k| list[k].code == 413 && list[k].indent < cmd.indent }
        [[j ? j + 1 : i + 1], st]
      when 115                            # exit event processing
        [:exit, st]
      when 119                            # jump to label
        j = (0...(list.size - 1)).find { |k| list[k].code == 118 && list[k].parameters[0] == params[0] }
        [[j || i + 1], st]
      when 117                            # call common event: it runs, then this list goes on
        ce = common_event(params[0])
        if ce && ce.list && depth < PRICE_DEPTH
          st = flow_prices(ce.list, st, found, unread, depth + 1)
          return [[], st] if st.nil?
        elsif ce && ce.list
          unread << "common event #{params[0]}, called too deep to follow"
        end
        [[fall_through(list, i)], st]
      when 355                            # a script, with the script commands right after it
        last = i
        last += 1 while list[last + 1] && [355, 655].include?(list[last + 1].code)
        text = (i..last).map { |k| list[k].parameters[0].to_s }.join("\n")
        [[fall_through(list, last)], script_prices(text, st, found, unread, [list.object_id, i])]
      else
        [[fall_through(list, i)], st]
      end
    end

    # The next command at +i+'s own level (a branch's else or end, the next choice).
    def same_level(list, i)
      ((i + 1)...list.size).find { |k| list[k].indent == list[i].indent }
    end

    # The command after +i+ when it simply runs on. The end of a branch's body skips its
    # else; the end of a choice's body skips the other choices.
    def fall_through(list, i)
      nxt = list[i + 1]
      return i + 1 unless nxt && nxt.indent < list[i].indent

      ends = { 411 => 412, 402 => 404, 403 => 404, 602 => 604, 603 => 604 }[nxt.code]
      return i + 1 unless ends

      ((i + 1)...list.size).find { |k| list[k].code == ends && list[k].indent == nxt.indent } || i + 1
    end

    # One script's price calls, in order. A script with Ruby control flow of its own may
    # run each call or not, and again: followed until nothing changes.
    def script_prices(text, st, found, unread, key)
      calls = price_calls(text)
      return st if calls.empty?

      calls.each { |c| unread << c[1] if c[0] == :unread }
      may = text.match?(SCRIPT_FLOW)
      cur = st
      loop do
        after = cur
        calls.each_with_index do |c, k|
          case c[0]
          when :set
            nxt = set_price(after, c[1], c[2], c[3])
            after = may ? join_prices(after, nxt) : nxt
          when :mart
            slot = (found[key + [k]] ||= [nil, c[1], false])
            slot[0] = join_prices(slot[0], after)
            slot[2] ||= c[2]
            after = may ? join_prices(after, {}) : {}
          end
        end
        return after unless may

        nxt = join_prices(cur, after)
        return nxt if nxt == cur

        cur = nxt
      end
    end

    # -> the price calls of one script, in order: [:set, item, buy, sell],
    # [:mart, kind, can_sell] or [:unread, the call's text].
    def price_calls(text)
      calls = []
      pos = 0
      while (m = PRICE_CALL.match(text, pos))
        args, pos = call_args(text, m.end(0))
        name = m[1]
        if name == "pbPokemonMart" || name == "pbBattlePointShop"
          kind = name == "pbPokemonMart" ? "mart" : "bp_shop"
          calls << [:mart, kind, kind == "mart" && args[2].to_s.strip != "true"]
          next
        end
        item = args[0].to_s.strip[/\A:([A-Za-z0-9_]+)\z/, 1]
        nums = name == "setSellPrice" ? ["-1", args[1]] : [args[1] || "-1", args[2] || "-1"]
        nums = nums.map { |n| n.to_s.strip }
        if item && nums.all? { |n| n.match?(/\A-?\d+\z/) }
          calls << [:set, item, nums[0].to_i, nums[1].to_i]
        else
          calls << [:unread, text[m.begin(0)...pos].strip]
        end
      end
      calls
    end

    # A call's arguments, split at its top-level commas, from just inside its "(" to the
    # matching ")". -> [[argument text, ...], the index past the ")"]
    def call_args(text, start)
      args  = []
      depth = 0
      quote = nil
      from  = start
      i     = start
      while i < text.length
        c = text[i]
        if quote
          if c == "\\"
            i += 1
          elsif c == quote
            quote = nil
          end
        elsif c == '"' || c == "'"
          quote = c
        elsif "([{".include?(c)
          depth += 1
        elsif ")]}".include?(c)
          if depth.zero?
            last = text[from...i]
            args << last unless args.empty? && last.strip.empty?
            return [args, i + 1]
          end
          depth -= 1
        elsif c == "," && depth.zero?
          args << text[from...i]
          from = i + 1
        end
        i += 1
      end
      [args << text[from..-1], text.length]
    end

    # Interpreter#setPrice, on each state an item's prices may be in: a buy price above 0
    # replaces the buy price; a sell price of 0 or more sells at twice it, else a new buy
    # price sells at itself.
    def set_price(st, item, buy, sell)
      pairs = (st[item] || [[-1, -1]]).map do |b, s|
        [buy > 0 ? buy : b, if sell >= 0 then sell * 2 elsif buy > 0 then buy else s end]
      end
      st.merge(item => pairs.uniq.sort)
    end

    # Either state (nil: no path leads here).
    def join_prices(a, b)
      return b if a.nil? || a == b
      return a if b.nil?

      out = {}
      (a.keys | b.keys).each { |item| out[item] = ((a[item] || [[-1, -1]]) | (b[item] || [[-1, -1]])).sort }
      out
    end

    # The game's common events, read once per export (none outside the engine).
    def common_event(id)
      @common_events ||= (load_data("Data/CommonEvents.rxdata") rescue nil) || []
      id.is_a?(Integer) ? @common_events[id] : nil
    end

    # Step 6 (the payout gate): what the server needs to judge a gift request.
    #   dynamic    - a call whose item is computed, so :items is not the whole list
    #   quantities - item => largest literal quantity (left out when one is computed)
    #   once       - a single call, on a page that turns on a switch, self-switch or
    #                variable a LATER page waits for: once paid, the event shows that
    #                page and cannot pay again, so a second payout means an edit
    def gift_facts(event, script)
      calls = receive_calls(script)
      quantities = {}
      computed = {}
      calls.each do |item, qty|
        next unless item

        if qty
          quantities[item] = [quantities[item] || 0, qty].max
        else
          computed[item] = true
        end
      end
      computed.each_key { |item| quantities.delete(item) }
      { :once => calls.length == 1 && !script.include?("pbSetEventTime") && pays_once?(event),
        :dynamic => calls.any? { |item, _| item.nil? }, :quantities => quantities }
    rescue
      {}
    end

    # -> [[item | nil, quantity | nil], ...], one per pbReceiveItem call: nil where the
    # argument is computed rather than written out.
    def receive_calls(script)
      out = []
      pos = 0
      while (i = script.index("pbReceiveItem(", pos))
        args, pos = call_args(script, i + "pbReceiveItem(".length)
        item = args[0] ? args[0][/\A:([A-Za-z0-9_]+)\z/, 1] : nil
        qty  = if args.length < 2 then 1
               elsif args[1].match?(/\A\d+\z/) then args[1].to_i
               end
        out << [item, qty]
      end
      out
    end

    # The top-level arguments of a call whose "(" ends just before +start+.
    # -> [[argument text, ...], index past the closing ")"]
    def call_args(text, start)
      args  = []
      cur   = +""
      depth = 0
      i = start
      while i < text.length
        ch = text[i]
        if "([{".include?(ch)
          depth += 1
          cur << ch
        elsif ")]}".include?(ch) && depth > 0
          depth -= 1
          cur << ch
        elsif ch == ")"
          break
        elsif ch == "," && depth == 0
          args << cur.strip
          cur = +""
        else
          cur << ch
        end
        i += 1
      end
      args << cur.strip unless args.empty? && cur.strip.empty?
      [args, i + 1]
    end

    # RMXP runs the highest-numbered page whose conditions hold, so once the paying
    # page turns on what a later page waits for, the event shows that page instead.
    def pays_once?(event)
      pages = event.pages
      k = pages.index { |pg| pg && pg.list && pg.list.any? { |c| receive_command?(c) } }
      return false unless k

      marks = page_marks(pages[k])
      pages[(k + 1)..-1].any? { |pg| pg && pg.condition && waits_on?(pg.condition, marks) }
    end

    def receive_command?(cmd)
      params = cmd.respond_to?(:parameters) ? cmd.parameters : nil
      return false unless params

      case cmd.code
      when 355, 655 then params[0].to_s.include?("pbReceiveItem(")
      when 111      then params[0] == 12 && params[1].to_s.include?("pbReceiveItem(")
      else false
      end
    end

    # What a page turns on: self-switches (123 ON), switches (121 ON) and variables
    # set to a constant (122 set, constant operand).
    def page_marks(page)
      marks = { :self => {}, :switches => {}, :variables => {} }
      page.list.each { |cmd| mark!(marks, cmd) }
      marks
    end

    # One command's mark, as page_marks reads them.
    def mark!(marks, cmd)
      params = cmd.respond_to?(:parameters) ? cmd.parameters : nil
      return unless params

      case cmd.code
      when 123 then marks[:self][params[0].to_s] = true if params[1] == 0
      when 121 then (params[0]..params[1]).each { |id| marks[:switches][id] = true } if params[2] == 0
      when 122
        (params[0]..params[1]).each { |id| marks[:variables][id] = params[4] } if params[2] == 0 && params[3] == 0
      end
    end

    def waits_on?(cond, marks)
      value = cond.variable_valid ? marks[:variables][cond.variable_id] : nil
      !!((cond.self_switch_valid && marks[:self][cond.self_switch_ch.to_s]) ||
         (cond.switch1_valid && marks[:switches][cond.switch1_id]) ||
         (cond.switch2_valid && marks[:switches][cond.switch2_id]) ||
         (value.is_a?(Integer) && value >= cond.variable_value))
    end

    # === trainers (where each trainer battle starts) — Layer D D4 ================

    # -> [[type, name, version, rematch], ...] for every TrainerBattle.start in the
    # event's scripts; a double battle names two trainers. Literal arguments only: a
    # computed trainer would export a bogus id. A phone rematch (Phone.battle) battles
    # the contact's next version, which the engine picks at runtime from the versions its
    # Phone.add registered (start ... start + count - 1): each is placed here, where the
    # event calls it, marked as a rematch - a battle that can be fought again. Without a
    # Phone.add in the event, every version from the start one onwards.
    def collect_trainers(event)
      return [] unless event && event.respond_to?(:pages) && event.pages

      script = event_script(event)
      return [] unless script

      found = battle_ids(script).map { |id| id + [false] }
      counts = {}
      script.scan(/Phone\.add\(\s*get_self\s*,\s*:([A-Za-z0-9_]+)\s*,\s*"([^"]*)"\s*(?:,\s*(\d+)\s*)?(?:,\s*(\d+))?/) do |type, name, count, start|
        counts[[type, name, start.to_i]] = [count ? count.to_i : 1, 1].max
      end
      script.scan(/Phone\.battle\(\s*:([A-Za-z0-9_]+)\s*,\s*"([^"]*)"(?:\s*,\s*(\d+))?/) do |type, name, start|
        next unless rematches_possible?   # never ready for a rematch: this call never runs

        first = start.to_i
        count = counts[[type, name, first]]
        trainer_versions(type, name).each do |v|
          found << [type, name, v, true] if v >= first && (count.nil? || v < first + count)
        end
      end
      rematches = found.select { |t| t[3] }.map { |t| t[0, 3] }
      found.reject { |t| !t[3] && rematches.include?(t[0, 3]) }.uniq
    rescue
      []
    end

    # The trainer battles a script starts: [[type, name, version], ...] (literal arguments
    # only - a computed trainer would export a bogus id).
    def battle_ids(script)
      battle_calls(script).flatten(1)
    end

    # ... one list per call: the trainers one battle faces together.
    def battle_calls(script)
      calls = []
      script.scan(/TrainerBattle\.start\(([^)]*)\)/) do |(args)|
        ids = []
        args.scan(/:([A-Za-z0-9_]+)\s*,\s*"([^"]*)"(?:\s*,\s*(\d+))?/) do |type, name, version|
          ids << [type, name, version.to_i]
        end
        calls << ids unless ids.empty?
      end
      calls
    end

    # Money authority M3: what each battle an event starts is, by its commands.
    # -> { [type, name, version] => [once, page, no_money] }
    # - once: every call starting it is a conditional branch (111, script) whose win turns
    #   on, at the branch's own level, all that a later page waits for - the event then
    #   shows that page. A mark under a further condition may never be set (the demo's
    #   repeat Grunt), a temporary switch is no page condition (Champion Blue), and a plain
    #   script call has no win of its own: anything else can be fought again.
    # - page: the index of the page it is on (the first, if several).
    # - no_money: every call follows a setBattleRule("noMoney") since the page's last
    #   battle - the engine pays nothing, and claims nothing.
    def battle_marks(event)
      seen = {}
      call = 0      # each TrainerBattle.start of the event, in order: the trainers of one battle
      event.pages.each_with_index do |pg, k|
        next unless pg && pg.list

        rules = +""   # the scripts since the last battle: the next one's rules
        plain = []    # the page's script lines, for the calls outside a branch
        pg.list.each_with_index do |cmd, i|
          params = cmd.respond_to?(:parameters) ? cmd.parameters : nil
          next unless params

          case cmd.code
          when 111
            next unless params[0] == 12 && params[1].to_s.include?("TrainerBattle.start(")

            marks = branch_marks(pg.list, i)
            won = event.pages[(k + 1)..-1].any? { |p| p && p.condition && shows_after?(p.condition, marks) }
            free = rules.match?(NO_MONEY)
            rules = +""
            battle_calls(params[1].to_s).each do |ids|
              ids.each { |id| note_battle(seen, id, k, won, free, call) }
              call += 1
            end
          when 355, 655
            rules << params[0].to_s << "\n"
            plain << params[0].to_s
          end
        end
        battle_calls(plain.join("\n")).each do |ids|
          ids.each { |id| note_battle(seen, id, k, false, false, call) }
          call += 1
        end
      end
      seen
    rescue
      {}
    end

    NO_MONEY = /setBattleRule\([^)]*["']nomoney["']/i.freeze
    NO_PARTNER = /setBattleRule\([^)]*["']nopartner["']/i.freeze

    # -> [once, page, no_money, the calls naming it]
    def note_battle(seen, id, page, won, free, call)
      prev = seen[id]
      seen[id] = if prev
                   [prev[0] && won && prev[1] == page, prev[1], prev[2] && free, prev[3] | [call]]
                 else
                   [won, page, free, [call]]
                 end
    end

    # What the branch opened at +list[i]+ turns on at its own level: the commands one
    # indent deeper, up to its else or its end. A mark nested deeper may never be set.
    def branch_marks(list, i)
      depth = list[i].indent
      marks = { :self => {}, :switches => {}, :variables => {} }
      list[(i + 1)..-1].each do |cmd|
        break if cmd.indent <= depth

        mark!(marks, cmd) if cmd.indent == depth + 1
      end
      marks
    end

    # Does a page with +cond+ show once +marks+ are on, whatever else holds? Every
    # condition it has is one of them.
    def shows_after?(cond, marks)
      held = []
      held << marks[:self][cond.self_switch_ch.to_s] if cond.self_switch_valid
      held << marks[:switches][cond.switch1_id] if cond.switch1_valid
      held << marks[:switches][cond.switch2_id] if cond.switch2_valid
      if cond.variable_valid
        value = marks[:variables][cond.variable_id]
        held << (value.is_a?(Integer) && value >= cond.variable_value)
      end
      !held.empty? && held.all?
    end

    # === badges (docs/BADGE-AUTHORITY-DESIGN.md, B0) ==========================

    BADGE_SET = /(?:\$player|\$Trainer|pbPlayer)\.badges\[\s*(\d+)\s*\]\s*=\s*true\b/.freeze
    # A write to the badges: one (any index, any value) or all at once (assigned, filled,
    # pushed...). "=(?!=)" counts "badges[1]=$player.badges[2]=true" as two writes.
    BADGE_WRITE = /\s*(?:\[[^\]]*\]\s*=(?!=)|=(?!=)|\|\|=|<<|\.(?:fill|push|unshift|insert|concat|replace|map!|collect!|clear|delete_at|store)\b)/.freeze
    BADGE_ANY = /(?:\$player|\$Trainer|pbPlayer)\.badges#{BADGE_WRITE}/.freeze
    # ... and in the game's code, the player's own too (@badges, self.badges) - but not the
    # engine's new game, which sets them all false.
    CODE_BADGE_ANY = /(?:(?:\$player|\$Trainer|pbPlayer|self)\.badges|@badges)#{BADGE_WRITE}/.freeze
    BADGE_RESET = /\A@badges\s*=\s*\[\s*false\s*\]\s*\*\s*\d+\z/.freeze
    # The sizes a battle rule sets; a battle that is not a single one asks no seed.
    SIZES = %w[single 1v1 1v2 2v1 1v3 3v1 double 2v2 2v3 3v2 triple 3v3].freeze
    # A win branch's condition: the battle call itself, nothing around it (a "!" would make
    # the branch the loss's).
    WIN_CONDITION = /\A\s*TrainerBattle\.start\([^()]*\)\s*\z/.freeze

    # Where each badge is given. -> { :list => [{ :badge, :map, :event, :page, :trainers }
    # | { :badge, :common_event }], :unknown => [{ where, :script }] }. A badge set at the
    # own level of a trainer battle's win branch names that battle's trainers; one set
    # anywhere else names none (no battle gives it); a set the export cannot read (a
    # computed index) is unknown.
    def badge_sources(all_events)
      list = []
      unknown = []
      all_events.each do |map_id, event|
        next unless event && event.respond_to?(:pages) && event.pages

        event.pages.each_with_index do |pg, k|
          next unless pg && pg.list

          won = badge_win_branches(pg.list)
          badge_scripts(pg.list) do |i, text|
            where = { :map => map_id, :event => event.id, :page => k }
            badge_sets(text) do |badge|
              entry = { :badge => badge }.merge(where)
              if won[i]
                entry[:trainers] = won[i][0]
                entry[:call] = won[i][4]                 # the page's battle command that gives it
                entry[:no_money] = true if won[i][1]     # no prize, so no claim to prove it
                entry[:no_partner] = true if won[i][2]   # fought alone: a partner never joins
                entry[:size] = won[i][3] if won[i][3]    # not a single battle: no seed is asked
              end
              list << entry
            end
            unknown << where.merge(:script => text.strip[0, 80]) unless badge_read?(text)
          end
        end
      end
      Array((load_data("Data/CommonEvents.rxdata") rescue nil)).each do |ce|
        next unless ce && ce.respond_to?(:list) && ce.list

        badge_scripts(ce.list) do |_i, text|
          badge_sets(text) { |badge| list << { :badge => badge, :common_event => ce.id } }
          unknown << { :common_event => ce.id, :script => text.strip[0, 80] } unless badge_read?(text)
        end
      end
      { :list => list, :unknown => unknown + badge_code_writes }
    end

    # Yields the badge of each literal set on a script line (a line may set several).
    def badge_sets(text)
      badge_code(text).scan(BADGE_SET) { |m| yield m[0].to_i }
    end

    # Is every badge write on the line a literal set? (else the export cannot say which)
    def badge_read?(text)
      code = badge_code(text)
      code.scan(BADGE_ANY).length == code.scan(BADGE_SET).length
    end

    # Yields each script line (355, 655) of +list+ that writes the badges: [index, text].
    def badge_scripts(list)
      list.each_with_index do |cmd, i|
        next unless [355, 655].include?(cmd.code)

        text = cmd.parameters[0].to_s
        yield i, text if badge_code(text).match?(BADGE_ANY)
      end
    end

    # The code of a script line: its comment cut, its strings emptied - a badge a message
    # or a comment names sets nothing.
    def badge_code(text)
      out = +""
      quote = nil
      escaped = false
      text.each_char do |ch|
        if quote
          if escaped
            escaped = false
          elsif ch == "\\"
            escaped = true
          elsif ch == quote
            quote = nil
            out << ch
          end
          next
        end
        break if ch == "#"

        quote = ch if ch == '"' || ch == "'"
        out << ch
      end
      out
    end

    # The size the rules set for the next battle when it is not a single one, else nil
    # (the last size set wins).
    def battle_size(rules)
      size = rules.scan(/setBattleRule\(([^)]*)\)/).flat_map { |(args)| args.scan(/["']([^"']+)["']/).flatten }
                  .map(&:downcase).select { |r| SIZES.include?(r) }.last
      size && !%w[single 1v1].include?(size) ? size : nil
    end

    # -> { command index => [[type, name, version], ...] } for the commands at the own
    # level of each trainer battle's win branch (up to its else or its end).
    # ... with whether that battle pays nothing (a "noMoney" rule since the page's last
    # battle), is fought alone (a "noPartner" rule), its size when not a single one, and
    # the index of its battle command:
    # -> { index => [trainers, no_money, no_partner, size, call] }
    def badge_win_branches(list)
      won = {}
      rules = +""   # the scripts since the last battle: the next one's rules
      list.each_with_index do |cmd, i|
        params = cmd.respond_to?(:parameters) ? cmd.parameters : nil
        next unless params

        rules << params[0].to_s << "\n" if [355, 655].include?(cmd.code)
        next unless cmd.code == 111 && params[0] == 12 && params[1].to_s.include?("TrainerBattle.start(")

        free = rules.match?(NO_MONEY)
        alone = rules.match?(NO_PARTNER)
        size = battle_size(rules)
        rules = +""
        next unless params[1].to_s.match?(WIN_CONDITION)

        trainers = battle_calls(params[1].to_s).flatten(1)
        next if trainers.empty?

        list[(i + 1)..-1].each_with_index do |c, j|
          break if c.indent <= cmd.indent

          won[i + 1 + j] = [trainers, free, alone, size, i] if c.indent == cmd.indent + 1
        end
      end
      won
    end

    # The game's own code that writes the badges (plugins, edited engine scripts): unknown
    # to the server. -> [{ :file, :line, :script }]
    def badge_code_writes
      code_lines.filter_map do |f, n, text|
        code = badge_code(text).strip
        next if !code.match?(CODE_BADGE_ANY) || code.match?(BADGE_RESET)

        { :file => f, :line => n, :script => text.strip[0, 80] }
      end
    rescue StandardError
      []
    end

    # Mode keys: the badge Surf and Dive need, as the game counts badges (a number of
    # them, or one in particular - Settings), and the event scripts and game code that
    # start a swim by themselves (a boat ride): a player may then surf with no key, so
    # the server only logs. -> { :count_badges, :surf, :dive, :mode_sources => [...] }
    def field_keys(all_events)
      surf = (Settings::BADGE_FOR_SURF rescue nil)
      dive = (Settings::BADGE_FOR_DIVE rescue nil)
      return nil unless surf.is_a?(Integer) && dive.is_a?(Integer)

      { :count_badges => (Settings::FIELD_MOVES_COUNT_BADGES rescue false) == true,
        :surf => surf, :dive => dive, :mode_sources => mode_sources(all_events),
        :surf_move => move_required?(%w[pbSurf]), :dive_move => move_required?(%w[pbDive pbSurfacing]) }
    end

    # Whether the game still asks for a Pokemon knowing the move before a swim: true when
    # each of +names+ (the engine's) still calls get_pokemon_with_move, false when the game
    # dropped it there, nil when a script of the game redefines one (its rule is unknown).
    def move_required?(names)
      engine = Dir.glob("Data/Scripts/**/#{MODE_OWN.first}").first
      return nil unless engine

      bodies = names.map { |n| def_body(File.read(engine), n) }
      return nil if bodies.any?(&:nil?)

      lines = (code_lines rescue [])
      return nil if lines.any? { |f, _, text| !f.end_with?(MODE_OWN.first) && text.match?(/^\s*def\s+(#{names.join('|')})\b/) }
      return nil if rule_redefined?(lines)

      bodies.all? { |b| b.include?("get_pokemon_with_move") }
    end

    # The readers the rule leans on - which Pokemon count, what knowing a move is - defined
    # again outside the engine's own files: the rule is then whatever that script says.
    RULE_SEATS = { "get_pokemon_with_move" => "001_Trainer.rb", "pokemon_party" => "001_Trainer.rb",
                   "hasMove?" => "001_Pokemon.rb" }.freeze

    def rule_redefined?(lines)
      lines.any? do |f, _, text|
        RULE_SEATS.any? { |name, seat| !f.end_with?(seat) && text.match?(/^\s*def\s+#{Regexp.escape(name)}(\s|\(|$)/) }
      end
    end

    # The lines of `def name` down to its `end`, or nil.
    def def_body(text, name)
      lines = text.lines
      i = lines.index { |l| l.match?(/^def\s+#{name}\b/) }
      return nil unless i

      j = lines[(i + 1)..].index { |l| l.match?(/^end\b/) }
      j ? lines[i..(i + 1 + j)].join : nil
    end

    # A script line that puts the player on the water with no field move: the game's own
    # Surf and Dive (FieldMoves.rb) and PEMK's snap-back aside.
    MODE_SET   = /\$PokemonGlobal\.(surfing|diving)\s*(\|\|)?=\s*true\b|\bpbStartSurfing\b/.freeze
    MODE_OWN   = %w[004_Overworld_FieldMoves.rb].freeze   # the engine's gated paths

    def mode_sources(all_events)
      out = []
      all_events.each do |map_id, event|
        next unless event && event.respond_to?(:pages) && event.pages

        event.pages.each_with_index do |pg, k|
          next unless pg && pg.list

          mode_scripts(pg.list) { |text| out << { :map => map_id, :event => event.id, :page => k, :script => text.strip[0, 80] } }
        end
      end
      Array((load_data("Data/CommonEvents.rxdata") rescue nil)).each do |ce|
        next unless ce && ce.respond_to?(:list) && ce.list

        mode_scripts(ce.list) { |text| out << { :common_event => ce.id, :script => text.strip[0, 80] } }
      end
      (code_lines rescue []).each do |f, n, text|
        code = badge_code(text)
        next if MODE_OWN.any? { |own| f.end_with?(own) } || !code.match?(MODE_SET)
        next if code.match?(/\b(def|alias|alias_method)\b/)   # a definition starts no swim

        out << { :file => f, :line => n, :script => text.strip[0, 80] }
      end
      out
    end

    def mode_scripts(list)
      list.each do |cmd|
        next unless cmd.respond_to?(:code) && [355, 655].include?(cmd.code)

        text = cmd.parameters[0].to_s
        yield text if badge_code(text).match?(MODE_SET)
      end
    end

    # The game's own code - its plugins and engine scripts, PEMK's own and the debug menu
    # aside: [file, line number, text] for each line that is not a comment.
    def code_lines
      files = Dir.glob("Plugins/**/*.rb").reject { |f| f.start_with?("Plugins/PEMK/") } +
              Dir.glob("Data/Scripts/**/*.rb").reject { |f| f.include?("020_Debug") }
      files.sort.flat_map do |f|
        File.readlines(f).each_with_index.filter_map { |text, i| [f, i + 1, text] unless text.lstrip.start_with?("#") }
      end
    end

    # Money authority: the partner trainers the game registers (pbRegisterPartner), whose
    # party may hold an Amulet Coin that doubles a prize - in map events, common events and
    # the game's own code (the engine's definition aside). A partner at the player's side
    # also means a battle with no seed (badge authority).
    def partner_registrations(maps_events)
      scripts = maps_events.filter_map { |_, event| event && event.respond_to?(:pages) && event.pages && event_script(event) }
      Array((load_data("Data/CommonEvents.rxdata") rescue nil)).each do |ce|
        scripts << list_script(ce.list) if ce && ce.respond_to?(:list) && ce.list
      end
      code = (code_lines rescue []).filter_map { |_, _, text| text if text.include?("pbRegisterPartner") && !text.match?(/\bdef\s+pbRegisterPartner\b/) }
      scripts << code.join("\n") unless code.empty?
      partners_in(scripts.compact)
    end

    # -> { :list => [[type, name, version], ...], :computed => a call names its partner at runtime }
    def partners_in(scripts)
      list = []
      computed = false
      scripts.each do |s|
        literal = 0
        s.scan(/pbRegisterPartner\(\s*:([A-Za-z0-9_]+)\s*,\s*"([^"]*)"(?:\s*,\s*(\d+))?\s*\)/) do |type, name, version|
          list << [type, name, version.to_i]
          literal += 1
        end
        computed ||= s.scan("pbRegisterPartner(").length > literal
      end
      { :list => list.uniq, :computed => computed }
    end

    # Can a phone contact of this game ever be ready for a rematch? The settings may allow
    # it from the start, or an event may turn it on (Phone.rematches_enabled). Otherwise
    # Phone.battle never runs - the demo's contacts were exported as rematches it can never
    # fight. Read once per export.
    def rematches_possible?
      return @rematches_possible unless @rematches_possible.nil?

      from_start = (Settings::PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING rescue false) ? true : false
      @rematches_possible = from_start || any_script_includes?("rematches_enabled")
    end

    # Does any map event or common event script mention +text+?
    def any_script_includes?(text)
      infos = (load_data("Data/MapInfos.rxdata") rescue nil) || {}
      in_maps = infos.keys.any? do |id|
        map = (load_data(sprintf("Data/Map%03d.rxdata", id)) rescue nil)
        map && map.respond_to?(:events) && map.events &&
          map.events.values.any? { |ev| (event_script(ev) || "").include?(text) }
      end
      in_maps || Array((load_data("Data/CommonEvents.rxdata") rescue nil)).any? do |ce|
        ce && ce.respond_to?(:list) && ce.list && (list_script(ce.list) || "").include?(text)
      end
    rescue StandardError
      false
    end

    # The versions the trainer data holds for +type+ and +name+, read once per export.
    def trainer_versions(type, name)
      @trainer_versions ||= begin
        all = Hash.new { |h, k| h[k] = [] }
        GameData::Trainer.each { |tr| all[[tr.trainer_type.to_s, tr.real_name.to_s]] << tr.version.to_i }
        all
      end
      @trainer_versions.fetch([type, name], []).sort
    rescue StandardError
      []
    end

    # Concatenate the searchable script text across all pages. RMXP stores item
    # balls as a CONDITIONAL BRANCH (code 111, subtype 12, text in params[1]), not a
    # plain Script command (code 355/655, text in params[0]) — read both.
    def event_script(event)
      parts = event.pages.filter_map { |page| page && page.list && list_script(page.list) }
      parts.empty? ? nil : parts.join("\n")
    end

    # The script text of one command list (an event page, a common event).
    def list_script(list)
      parts = []
      list.each do |cmd|
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
      parts.empty? ? nil : parts.join("\n")
    end

    # === item sources the server cannot credit — item authority E1b ============

    # Calls that put an item in the player's hands without a request the server answers
    # for that exact item: an item added straight to the bag, a gift or item ball whose
    # item is computed, a Game Corner prize, a Mystery Gift (its items come from a file
    # or a download, never from the event). With the literal gifts, item balls and shop
    # stocks already exported, this names every other way the events can produce an
    # item, so the server knows which items it can judge.
    UNHOOKED = %w[$bag.add( pbBuyPrize( pbReceiveMysteryGift(].freeze

    # -> { :calls => [...], :items => [...], :unbounded => bool } | nil for one script.
    # +common+: a common event, which no request can name, so even its literal gifts and
    # item balls count here.
    def item_source(script, common: false)
      return nil unless script

      calls = UNHOOKED.select { |c| script.include?(c) }.map { |c| c.chomp("(") }
      computed = receive_calls(script).any? { |item, _| item.nil? } ||
                 script.scan(/pbItemBall\(\s*([^,)\s]+)/).flatten.any? { |a| !a.start_with?(":") }
      calls << "computed" if computed
      calls << "pbReceiveItem" if common && script.include?("pbReceiveItem(")
      calls << "pbItemBall" if common && script.include?("pbItemBall(")
      return nil if calls.empty?

      items = script.scan(/:([A-Z][A-Z0-9_]*)/).flatten.uniq.select { |i| item_id?(i) }
      { :calls => calls.uniq, :items => items, :unbounded => items.empty? }
    rescue
      nil
    end

    def item_id?(name)
      GameData::Item.exists?(name.to_sym)
    rescue StandardError
      false
    end

    # Every map event's and common event's item source, and whether the game has berry
    # plants (every berry can then multiply) or the mining game.
    def item_sources(maps_events)
      list = []
      scripts = []
      maps_events.each do |map_id, event|
        script = event_script(event)
        scripts << script if script
        src = item_source(script)
        list << { :map => map_id, :event => event.id }.merge(src) if src
      end
      commons = (load_data("Data/CommonEvents.rxdata") rescue nil)
      Array(commons).each do |ce|
        next unless ce && ce.respond_to?(:list) && ce.list

        script = list_script(ce.list)
        scripts << script if script
        src = item_source(script, common: true)
        list << { :common_event => ce.id }.merge(src) if src
      end
      text = scripts.join("\n")
      { :events => list, :berry_plants => text.include?("pbBerryPlant") || text.include?("pbPickBerry("),
        :mining => text.include?("pbMiningGame") }
    end

    # === money sources the server cannot credit — money authority M0 ==========

    # Calls that pay by themselves: Triple Triad sells cards for money, the Game Corner's
    # machines pay coins.
    MONEY_CALLS = { "pbSellTriads" => "money", "pbSlotMachine" => "coins", "pbVoltorbFlip" => "coins" }.freeze
    # A script that adds to a balance, or sets it outright.
    BALANCE_ADD = /(?:\$player|pbPlayer|\$Trainer)\.(money|coins|battle_points)\s*\+=\s*([^\n;]+)/.freeze
    BALANCE_SET = /(?:\$player|pbPlayer|\$Trainer)\.(money|coins|battle_points)\s*=(?!=)/.freeze

    # Every way an event can raise the player's money, coins or battle points without a
    # request the server answers: Change Gold (code 125) increases with their literal
    # amounts (a variable amount is computed), scripts that add to a balance or set it,
    # and the calls that pay by themselves. A spend is not a source. With the prizes and
    # the server's own deals, this names every other way money can appear, so enforcement
    # can refuse to start while any of them is unbounded.
    # -> { :events => [{ :map, :event | :common_event, :calls, :fields, :amounts, :computed }] }
    def money_sources(maps_events)
      list = []
      maps_events.each do |map_id, event|
        next unless event && event.respond_to?(:pages) && event.pages

        src = money_source(event.pages.filter_map { |page| page && page.list })
        list << { :map => map_id, :event => event.id }.merge(src) if src
      end
      commons = (load_data("Data/CommonEvents.rxdata") rescue nil)
      Array(commons).each do |ce|
        next unless ce && ce.respond_to?(:list) && ce.list

        src = money_source([ce.list])
        list << { :common_event => ce.id }.merge(src) if src
      end
      { :events => list }
    end

    # -> { :calls, :fields, :amounts, :computed } | nil for the command lists of one event.
    def money_source(lists)
      calls    = []
      fields   = []
      amounts  = []
      computed = false
      lists.each do |list|
        list.each do |cmd|
          next unless cmd.respond_to?(:code) && cmd.code == 125 && cmd.parameters && cmd.parameters[0] == 0

          calls << "change_gold"   # an increase; 1 is a decrease
          fields << "money"
          if cmd.parameters[1] == 0
            amounts << cmd.parameters[2].to_i
          else
            computed = true        # the amount is read from a variable
          end
        end
        script = list_script(list)
        next unless script

        script.scan(BALANCE_ADD) do |field, arg|
          calls << "script"
          fields << field
          if arg.strip.match?(/\A\d+\z/)
            amounts << arg.strip.to_i
          else
            computed = true
          end
        end
        script.scan(BALANCE_SET) do |(field)|
          calls << "script"
          fields << field
          computed = true
        end
        MONEY_CALLS.each do |call, field|
          next unless script.include?(call)

          calls << call
          fields << field
          computed = true
        end
      end
      return nil if calls.empty?

      { :calls => calls.uniq, :fields => fields.uniq, :amounts => amounts, :computed => computed }
    rescue
      nil
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

        tt = terrain_of(terrain_tags, tid)
        next if tt && tt.ignore_passability   # e.g. :Neutral — the tile's passage bits don't apply
        return 0 if tt && tt.bridge           # a BRIDGE tile is walkable: the engine's bridge logic
                                              # overrides the impassable water/tile passage below it

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

    # === water — Layer B for surfers and divers =================================

    # -> Array of H row strings (W chars) | nil when the map holds no water. 'w' where a
    # surfer may be, 'd' where it may also dive or surface, 'x' deep water under a rock
    # (terrain_tag skips the rock, so a diver may come up onto it; no surfer gets there),
    # '.' elsewhere. The passability grid flattens water to walls; this says which of
    # them a surfer crosses.
    def map_water(map)
      return nil unless $data_tilesets

      tileset = $data_tilesets[map.tileset_id]
      return nil unless tileset && tileset.respond_to?(:terrain_tags)

      passages     = tileset.passages
      priorities   = tileset.priorities
      terrain_tags = tileset.terrain_tags
      data = map.data
      any  = false
      rows = Array.new(map.height) do |y|
        row = +""
        map.width.times do |x|
          surf = surf_tile?(data, x, y, passages, priorities, terrain_tags)
          deep = deep_tile?(data, x, y, terrain_tags)
          c = if surf && deep then "d"
              elsif surf then "w"
              elsif deep then "x"
              else "."
              end
          any ||= c != "."
          row << c
        end
        row
      end
      any ? rows : nil
    rescue
      nil
    end

    # Game_Map#playerPassable? for a surfer off a bridge: going down the layers, a water
    # tile decides unless a blocking or ground tile comes first. A waterfall counts (it
    # is climbed with through set). A tile blocked from some sides only does not stop
    # the scan: the surfer may reach it from another.
    def surf_tile?(data, x, y, passages, priorities, terrain_tags)
      [2, 1, 0].each do |z|
        tid = data[x, y, z]
        next if tid.nil? || tid == 0

        tt = terrain_of(terrain_tags, tid)
        next if tt && tt.bridge
        return true if tt && tt.can_surf
        next if tt && tt.ignore_passability

        return false if passages[tid] & 0x0f == 0x0f || priorities[tid] == 0
      end
      false
    rescue
      false
    end

    # Game_Map#terrain_tag off a bridge can dive: where Dive goes down, and where a
    # diver comes up on the map above.
    def deep_tile?(data, x, y, terrain_tags)
      [2, 1, 0].each do |z|
        tid = data[x, y, z]
        next if tid.nil? || tid == 0

        tt = terrain_of(terrain_tags, tid)
        next unless tt
        next if tt.id_number == 0 || tt.ignore_passability || tt.bridge

        return tt.can_dive ? true : false
      end
      false
    rescue
      false
    end

    # The map Dive takes a player down to from this one (its metadata's DiveMap) | nil.
    def dive_map_of(map_id)
      md = (GameData::MapMetadata.try_get(map_id) rescue nil)
      d = md && md.dive_map_id
      d.is_a?(Integer) && d > 0 ? d : nil
    rescue
      nil
    end

    # The map a diver on this one comes up to: the first whose DiveMap it is, in the
    # order pbSurfacing searches | nil.
    def surface_map_of(map_id)
      GameData::MapMetadata.each do |md|
        return md.id if md.dive_map_id == map_id
      end
      nil
    rescue
      nil
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

  # Dev/test helper: reset the self-switches of the event you're FACING, so a taken
  # item ball reappears — lets you re-test pickups (Layer C server-mint: the re-pickup
  # gets denied "already_taken"). Also handy for re-running any one-shot event.
  MenuHandlers.add(:debug_menu, :pemk_reset_facing_event, {
    "name"        => _INTL("PEMK: Reset facing event (self-switches)"),
    "parent"      => :main,
    "description" => _INTL("Turn off self-switches A-D of the event directly in front of the player (re-arm a taken item ball to re-test Layer C)."),
    "always_show" => false,
    "effect"      => proc {
      px = $game_player.x; py = $game_player.y
      d  = $game_player.direction
      fx = px + (d == 6 ? 1 : (d == 4 ? -1 : 0))   # tile in front
      fy = py + (d == 2 ? 1 : (d == 8 ? -1 : 0))
      hit = []
      ($game_map.events.each_value do |ev|
        next unless (ev.x == px && ev.y == py) || (ev.x == fx && ev.y == fy)   # on OR in front
        %w[A B C D].each { |s| $game_self_switches[[$game_map.map_id, ev.id, s]] = false }
        hit << ev.id
      end rescue nil)
      if hit.empty?
        pbMessage(_INTL("No event on or in front of you. Stand ON (item balls you walk onto) or FACE the ball, then use this."))
      else
        $game_map.need_refresh = true
        pbMessage(_INTL("Reset event(s) {1}. Step off & back on (or face + press A) to re-trigger.", hit.join(", ")))
      end
      next
    }
  })

  # Dev/QA-only: ask the SERVER to forget this account's taken pickups (Layer C keeps a
  # permanent one-shot per account, like the money ledger — so re-testing a taken ball
  # needs a server-side wipe). Honored only when the server was booted with
  # PEMK_ALLOW_PICKUP_RESET=on; production leaves it off, so this stays inert there.
  # Pair it with "Reset facing event" (self-switches) to make the ball re-appear locally.
  MenuHandlers.add(:debug_menu, :pemk_reset_pickups, {
    "name"        => _INTL("PEMK: Reset my pickups (dev)"),
    "parent"      => :main,
    "description" => _INTL("Ask the server to forget this account's taken item balls so they can be picked up again (needs PEMK_ALLOW_PICKUP_RESET=on)."),
    "always_show" => false,
    "effect"      => proc {
      if !(PEMK::Pickup.online? rescue false)
        pbMessage(_INTL("Not connected — log in to an MMO server first."))
      elsif !(PEMK::Pickup.reset_allowed? rescue false)
        pbMessage(_INTL("The server does not allow pickup reset. Boot it with PEMK_ALLOW_PICKUP_RESET=on (dev only)."))
      else
        reply = (PEMK::Pickup.request_reset rescue nil)
        if reply && reply[:type] == :pickups_reset_ok
          pbMessage(_INTL("Server cleared {1} recorded pickup(s). Reset the balls' self-switches (or new game) and they can be picked up again.", reply[:cleared].to_i))
        elsif reply && reply[:type] == :pickups_reset_deny
          pbMessage(_INTL("Server refused the pickup reset ({1}).", reply[:reason].to_s))
        else
          pbMessage(_INTL("No response from the server (timeout)."))
        end
      end
      next
    }
  })
end
