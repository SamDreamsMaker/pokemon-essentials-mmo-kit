# frozen_string_literal: true

module Autotest
  # One game window and the account it plays. Its instance name keeps its config,
  # session, log and local save apart from every other window (PEMK_INSTANCE); the
  # account is created on first login through the config credentials.
  class Player
    PASSWORD = "autotest-password"
    SETTLE   = 0.8   # seconds without a new line or question that end a conversation
    VERBS = %w[press hold release wait wait_until choose type pick dismiss walk_to talk_to enter
               face interact warp events event_pages grass battle decide fast advance screenshot save
               set_switch get_switch set_var get_var set_selfswitch get_selfswitch
               add_item get_item add_pokemon set_badge heal money bp set_raw_var set_raw_switch abort
               hold_saves pc_deposit pc_withdraw get_pc give_held take_held get_held partner set_debug].freeze

    attr_reader :name, :instance, :email, :pid

    def initialize(scenario, name, instance:, email:)
      @scenario = scenario
      @name     = name
      @instance = instance
      @email    = email
      @dir      = File.join(GAME_DIR, "autopilot", instance)
      @channel  = Channel.new(@dir)
    end

    def config_path;  File.join(GAME_DIR, "mmo_config_#{@instance}.txt"); end
    def log_path;     File.join(GAME_DIR, "mmo_#{@instance}.log"); end
    def channel_dir;  @dir; end

    def local_files
      [File.join(Windows.appdata, "Pokemon Essentials MMO Kit", "Game_#{@instance}.rxdata"),
       log_path, File.join(GAME_DIR, "mmo_session_#{@instance}.dat"),
       File.join(GAME_DIR, "mmo_account_#{@instance}.dat")]
    end

    # fresh: forget every local trace of an earlier run under this instance name.
    def launch(fresh: false)
      local_files.each { |f| FileUtils.rm_f(f) } if fresh
      File.write(config_path, "host = 127.0.0.1\nport = #{@scenario.server.port}\n" \
                              "email = #{@email}\npassword = #{PASSWORD}\n")
      FileUtils.mkdir_p(@dir)
      %w[cmd.txt resp.txt .cmd.tmp .resp.tmp].each { |f| FileUtils.rm_f(File.join(@dir, f)) }
      @pid = Windows.launch(@instance, @dir)
      @scenario.run_ctx.track_pid(@pid)
      wait_for_ping(90)
      self
    end

    def wait_for_ping(seconds)
      deadline = Autotest.mono + seconds
      loop do
        return true if (@channel.call("ping", timeout: 3) rescue nil)
        raise Failure, "#{@name}: the window exited while booting" unless Windows.alive?(@pid)
        raise Failure, "#{@name}: no answer from the window after #{seconds}s" if Autotest.mono > deadline

        sleep 1
      end
    end

    # One autopilot command; recorded in the scenario transcript.
    def ap(line, timeout: 30)
      reply = @channel.call(line, timeout: timeout)
      @scenario.transcript << { "player" => @name, "command" => line, "reply" => reply }
      reply
    end

    # The same, but a failed reply fails the scenario on the spot.
    def ap!(line, timeout: 30)
      reply = ap(line, timeout: timeout)
      raise Failure, "#{@name}: #{line} -> #{reply['error'] || reply['detail'] || reply.to_s[0, 300]}" unless reply["ok"]

      reply
    end

    VERBS.each do |verb|
      define_method(verb) { |*args, timeout: 30| ap([verb, *args].join(" ").strip, timeout: timeout) }
      define_method("#{verb}!") { |*args, timeout: 30| ap!([verb, *args].join(" ").strip, timeout: timeout) }
    end

    # A test's own setup is a source no server knows: with item authority on, the harness
    # credits the account first, as a pickup or a purchase would (E2).
    def add_item(item, qty = 1, timeout: 30)
      @scenario.credit_setup(self, item, qty)
      ap(["add_item", item, qty].join(" "), timeout: timeout)
    end

    def add_item!(item, qty = 1, timeout: 30)
      @scenario.credit_setup(self, item, qty)
      ap!(["add_item", item, qty].join(" "), timeout: timeout)
    end

    # Money a test hands out itself: explained to the server's shadow balance first.
    def money!(value, timeout: 30)
      @scenario.explain_money_setup(self, value)
      ap!("money #{value}", timeout: timeout)
    end

    def state
      ap("state")
    end

    def idle?(within = 2)
      ap("wait_until idle within #{within}", timeout: within + 10)["ok"]
    end

    # A crash, as far as the game can tell: no exit backstop, no last save.
    def hard_kill
      return unless @pid

      Windows.kill(@pid)
      deadline = Autotest.mono + 10
      sleep 0.3 while Windows.alive?(@pid) && Autotest.mono < deadline
      @pid = nil
    end

    # Close and start again on the same account; hands back once the saved game is
    # loaded and idle (the login bypasses the load screen when the server has a save).
    def relaunch
      hard_kill
      launch(fresh: false)
      wait_in_game
    end

    def wait_in_game(seconds = 60)
      deadline = Autotest.mono + seconds
      loop do
        st = state
        return st if st["map"] && st.dig("online", "logged_in") && idle?(1)
        raise Failure, "#{@name}: not back in the game after #{seconds}s" if Autotest.mono > deadline

        sleep 0.5
      end
    end

    def log_tail(count = 40)
      File.exist?(log_path) ? File.readlines(log_path, chomp: true).last(count) : []
    end

    # Reads a conversation to its end, answering each question with the next answer:
    # a menu entry, an item to pick, or a text to type. Fails when a question comes
    # with no answer left, or when answers are left over.
    def converse(*answers, seconds: 90)
      queue = answers.map(&:to_s)
      deadline = Autotest.mono + seconds
      loop do
        raise Failure, "#{@name}: the conversation is still going after #{seconds}s" if Autotest.mono > deadline

        r = dismiss!(timeout: 90)
        stop = r["stopped"]
        if stop.nil?
          next unless idle?(5)
          # It can pick up again a moment later (a blackout's walk home, then the
          # welcome there): only a quiet spell ends it.
          next if ap("wait_until message|menu|text|item|battle within #{SETTLE}", timeout: 10)["ok"]
          raise Failure, "#{@name}: the conversation ended with answers left: #{queue.inspect}" unless queue.empty?

          return r
        end
        # A battle starting ends it (an accepted challenge), once nothing is left to say.
        return r if stop == "battle" && queue.empty?

        answer = queue.shift
        unless answer
          raise Failure, "#{@name}: a #{stop} came with no answer left (#{r['message'].inspect} #{r['menus'].inspect})"
        end

        case stop
        when "menu" then choose!(answer)
        when "item" then pick!(answer)
        when "text" then type!(answer)
        else raise Failure, "#{@name}: the conversation stopped at a #{stop}"
        end
      end
    end

    def party_species
      Array(state["party"]).map { |p| p["species"] }
    end

    def in_battle?(within = 1)
      ap("wait_until battle within #{within}", timeout: within + 10)["ok"]
    end

    # Walks back and forth over two neighbouring grass tiles (the nearest pair it can
    # reach) until a wild battle starts. Bounded.
    def find_wild_battle(seconds: 120)
      deadline = Autotest.mono + seconds
      grass_pairs.first(10).each do |pair|
        loop do
          walks = pair.map { |x, y| walk_to(x, y, timeout: 30) }
          return true if in_battle?
          break unless walks.all? { |r| r["ok"] }            # out of reach: the next pair
          raise Failure, "#{@name}: no wild battle after #{seconds}s" if Autotest.mono > deadline
        end
      end
      raise Failure, "#{@name}: no reachable grass for a wild battle"
    end

    # Neighbouring grass tiles of this map, the nearest first.
    def grass_pairs
      tiles = Array(grass!["tiles"])
      known = tiles.to_h { |t| [t, true] }
      me = state["player"] || {}
      pairs = tiles.flat_map { |x, y| [[x + 1, y], [x, y + 1]].select { |n| known[n] }.map { |n| [[x, y], n] } }
      pairs.sort_by { |(x, y), _| (x - me["x"].to_i).abs + (y - me["y"].to_i).abs }
    end

    # Plays the wild battle: +warm_up+ turns of the lead's first move (the foe
    # attacks meanwhile), then +ball+ at every turn until it ends, or fights on once
    # the bag has none left. A fainted lead is replaced by the first able Pokemon;
    # anything else takes its first choice. Bounded.
    def catch_with(ball, warm_up: 0, seconds: 150)
      battle!("mode", "agent")
      deadline = Autotest.mono + seconds
      turns = 0
      loop do
        r = ap!("wait_until decision|no_battle within 30", timeout: 40)
        return true if r["matched"] == "no_battle"
        raise Failure, "#{@name}: the battle is still on after #{seconds}s" if Autotest.mono > deadline

        awaiting = state.dig("battle", "awaiting") || {}
        case awaiting["kind"]
        when "command"
          throw_one = turns >= warm_up && get_item!(ball)["quantity"].to_i.positive?
          decide!(throw_one ? "bag" : "fight")
          turns += 1
        when "fight"                                       # warm-up: the first move; then the strongest
          moves = Array(awaiting["options"]).select { |o| o["usable"] }
          pick = turns <= warm_up ? moves.first : moves.max_by { |o| [o["power"].to_i, -o["index"].to_i] }
          decide!(pick ? pick["index"].to_s : "0")
        when "item" then decide!(ball)
        when "party"
          able = Array(awaiting["options"]).find { |o| o["able"] && !o["active"] }
          decide!(able ? able["index"].to_s : "cancel")
        when "name" then decide!("")                       # no nickname
        else             decide!("0")
        end
      end
    ensure
      (battle("mode", "keys", timeout: 5) rescue nil)
    end

    # Plays a battle to its end with the strongest move. +swap_to+ (a party index)
    # sends that Pokemon in on the first turn instead, so the lead only takes part.
    # A fainted Pokemon is replaced by the first able one; no new move is learnt;
    # anything else takes its first choice. Bounded.
    # +prefer+: a move id used whenever it is usable (else the strongest usable move).
    def fight_battle(swap_to: nil, prefer: nil, seconds: 180)
      battle!("mode", "agent")
      deadline = Autotest.mono + seconds
      swapped = swap_to.nil?
      loop do
        r = ap!("wait_until decision|no_battle within 30", timeout: 40)
        return true if r["matched"] == "no_battle"
        raise Failure, "#{@name}: the battle is still on after #{seconds}s" if Autotest.mono > deadline

        awaiting = state.dig("battle", "awaiting") || {}
        options = Array(awaiting["options"])
        case awaiting["kind"]
        when "command" then decide!(swapped ? "fight" : "pokemon")
        when "fight"
          usable = options.select { |o| o["usable"] }
          best = (prefer && usable.find { |o| o["id"] == prefer }) ||
                 usable.max_by { |o| [o["power"].to_i, -o["index"].to_i] }
          decide!(best ? best["index"].to_s : "0")
        when "party"
          pick = swapped ? options.find { |o| o["able"] && !o["active"] } : options.find { |o| o["index"] == swap_to }
          swapped = true
          decide!(pick ? pick["index"].to_s : "cancel")
        when "forget" then decide!("cancel")
        when "name"   then decide!("")
        else               decide!("0")
        end
      end
    ensure
      (battle("mode", "keys", timeout: 5) rescue nil)
    end

    # Holds an arrow over a map edge until the next map is loaded.
    def cross(key, map)
      hold!(key)
      wait_until!("map #{map} within 10", timeout: 20)
      release!(key)
      wait_until!("idle within 5", timeout: 15)
    end

    # The other players this window draws on its map, by name.
    def remote_names
      Array(state["remotes"]).map { |r| r["name"] }
    end

    # Opens the pause menu and picks an entry. The engine opens it only for a player
    # standing still, so this waits for that first.
    def pause_menu(entry, seconds: 15)
      raise Failure, "#{@name}: not idle, the pause menu cannot open" unless idle?(seconds)

      press!("ACTION")
      ap!("wait_until menu_with #{entry} within #{seconds}", timeout: seconds + 10)
      choose!(entry)
    end

    # Waits for a question whose answers include +entry+ (a prompt raised by the
    # other player, say), then goes through the conversation with +answers+.
    def answer_when_asked(entry, *answers, seconds: 30)
      ap!("wait_until menu_with #{entry} within #{seconds}", timeout: seconds + 10)
      converse(*answers)
    end

    # A new account starts the intro at once: skip the help, choose, type the name,
    # read on, until the player stands idle in their house. Bounded.
    def new_game(player_name = "Autotest", seconds: 150)
      deadline = Autotest.mono + seconds
      loop do
        raise Failure, "#{@name}: the intro did not finish in #{seconds}s" if Autotest.mono > deadline

        st = state
        return st if st.dig("map", "id").to_i > 1 && idle?

        if st["text_entry"]
          type!(player_name)
        elsif (menu = Array(st["menus"]).last)
          commands = Array(menu["commands"])
          # Skip the help, pick a character, confirm the name ("So you're Ash?").
          pick = (["No info needed", "Boy", "Yes"] & commands).first
          raise Failure, "#{@name}: an unexpected menu in the intro: #{commands.inspect}" unless pick

          choose!(pick)
        elsif st["message"]
          dismiss!(200, timeout: 120)
        else
          ap("wait_until message|menu|text|idle within 5", timeout: 15)
        end
      end
    end
  end
end
