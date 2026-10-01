#===============================================================================
# PEMK :: Autopilot::BattleControl  (battle decisions for the agent)
#-------------------------------------------------------------------------------
# A battle asks the player for a decision at a handful of points, all on
# Battle::Scene: the command menu, the move, the target, the party screen, the bag,
# yes/no and other prompts, forgetting a move, and a nickname. Each point is hooked:
#   keys   (default) the engine's own UI runs; the point is only reported in "state"
#   agent  the point waits for a "decide" command
#   auto   a plain policy answers: the strongest usable move, the first healthy
#          Pokémon, the default answer to prompts
# Either way the Battle code receives exactly the value its UI would have returned,
# so everything after the choice (move registration, the PEMK PvP sync, RNG
# recording, server-adjudicated catches) runs unchanged.
#===============================================================================
module PEMK
  module Autopilot
    module BattleControl
      MODES = %w[keys agent auto].freeze

      # Stands in for the party or bag screen the engine hands to its checks, so a
      # refusal ("X is already in battle!") lands in the log instead of on a screen.
      module MessageSink
        module_function

        def pbDisplay(msg)
          Observe.note(msg, "battle")
        end
      end

      # A policy that keeps getting refused (every move rejected, running from a
      # trainer) would loop forever on one turn; past this many questions in the
      # same turn the keys are handed back and the log says why.
      MAX_ASKS_PER_TURN = 60

      @mode     = :keys
      @scene    = nil
      @awaiting = nil   # the decision point being asked, as reported in "state"
      @values   = nil   # label -> engine value for the pending point
      @decision = nil   # set by "decide", consumed by the waiting point
      @serial   = 0     # bumped at every decision point
      @result   = true  # whether the engine accepted the last decision
      @turn     = nil
      @asks     = 0

      module_function

      def mode;      @mode;      end
      def awaiting;  @awaiting;  end
      def serial;    @serial;    end
      def result;    @result;    end
      def attached?; !@scene.nil?; end

      def mode=(name)
        @mode = name.to_sym
      end

      # The player is at the keys: keys mode, or a server that took the autopilot's hands
      # off (PEMK::DebugLock) - the engine's own UI runs.
      def at_keys?
        @mode == :keys || !Autopilot.driving?
      end

      def attach(scene)
        @scene = scene
        @awaiting = nil
        @decision = nil
        @turn = nil
        @asks = 0
      end

      def detach
        @scene = nil
        @awaiting = nil
        @decision = nil
      end

      def battle
        @scene && @scene.instance_variable_get(:@battle)
      end

      # --- the decision points ------------------------------------------------

      # Reports the point, then -> the decision, or :keys when the engine's own UI
      # should run. The auto block computes the policy's answer.
      def ask(scene, kind, idx_battler, options, values = nil, &auto)
        @serial  += 1
        @awaiting = { "kind" => kind, "battler" => idx_battler, "options" => options }
        @values   = values
        @decision = nil
        count_ask
        loop do
          return :keys if at_keys?
          return auto ? auto.call : :keys if @mode == :auto
          scene.pbUpdate   # renders; the autopilot tick stores a "decide" meanwhile
          next unless @decision

          d = @decision
          @decision = nil
          @result = true
          return d
        end
      end

      def count_ask
        turn = (battle.turnCount rescue nil)
        if turn != @turn
          @turn = turn
          @asks = 0
        end
        @asks += 1
        return unless @asks > MAX_ASKS_PER_TURN && @mode != :keys

        Observe.note("autopilot: #{@asks} questions in one turn, handing the keys back", "battle")
        @mode = :keys
      end

      # Whether the engine took the decision (fight, party and bag can refuse one).
      def result!(accepted)
        @result = accepted ? true : false
      end

      def done
        @awaiting = nil
      end

      # "decide VALUE" from the channel. -> [ok, error]
      def decide(raw)
        a = @awaiting
        return [false, "no battle decision is pending"] unless a
        return [false, "battle mode is #{@mode}; switch to agent first"] unless @mode == :agent

        value = parse(a, raw.to_s.strip)
        return [false, "invalid #{a['kind']} decision #{raw.to_s.strip.inspect}"] if value.nil?

        @decision = value
        [true, nil]
      end

      # Maps the agent's answer to what the engine expects for this point.
      def parse(awaiting, raw)
        kind = awaiting["kind"]
        opts = awaiting["options"]
        down = raw.downcase
        case kind
        when "command", "choice", "confirm"
          i = pick_index(opts.map(&:to_s), raw)
          i && (@values ? @values[i] : i)
        when "fight"
          return -1 if down == "cancel"
          return -3 if down == "shift"
          return -2 if down == "mega"

          m = opts.find { |o| o["index"].to_s == raw || o["name"].to_s.casecmp?(raw) || o["id"].to_s.casecmp?(raw) }
          m && m["index"]
        when "target", "party"
          return :cancel if down == "cancel"

          t = opts.find { |o| o["index"].to_s == raw || o["name"].to_s.casecmp?(raw) }
          t && t["index"]
        when "forget"
          return -1 if %w[none cancel -1].include?(down)

          m = opts.find { |o| o["index"].to_s == raw || o["name"].to_s.casecmp?(raw) }
          m && m["index"]
        when "item"
          return :cancel if down == "cancel"

          item, target = raw.split
          item && [item.upcase.to_sym, target && Integer(target, exception: false)]
        when "name"
          raw
        end
      end

      def pick_index(labels, raw)
        return raw.to_i if raw.match?(/\A\d+\z/) && raw.to_i < labels.length

        labels.index { |l| l.casecmp?(raw) }
      end

      # --- what "state" shows ---------------------------------------------------

      def snapshot
        b = battle
        return nil unless b

        { "mode" => @mode.to_s, "awaiting" => @awaiting,
          "wild" => (b.wildBattle? rescue nil), "round" => (b.turnCount rescue nil),
          "battlers" => b.battlers.each_with_index.map { |x, i| x && battler_info(x, i) }.compact }
      rescue StandardError
        nil
      end

      def battler_info(battler, index)
        { "index" => index, "side" => index.even? ? "player" : "foe", "name" => battler.name,
          "species" => battler.species.to_s, "level" => battler.level, "hp" => battler.hp,
          "total_hp" => battler.totalhp, "status" => battler.status.to_s,
          "fainted" => battler.fainted? ? true : false }
      end

      def command_point(scene, idx_battler, first_action)
        b = scene.instance_variable_get(:@battle)
        last = if GameData::Type.exists?(:SHADOW) && b.trainerBattle? then ["call", 4]
               elsif first_action then ["run", 3]
               else ["cancel", -1]
               end
        [%w[fight bag pokemon] + [last[0]], [0, 1, 2, last[1]]]
      end

      def move_options(scene, idx_battler)
        b = scene.instance_variable_get(:@battle)
        battler = b.battlers[idx_battler]
        battler.moves.each_with_index.map do |m, i|
          next nil unless m && m.id

          { "index" => i, "name" => m.name, "id" => m.id.to_s, "pp" => m.pp, "total_pp" => m.total_pp,
            "type" => m.type.to_s, "power" => (m.respond_to?(:power) ? m.power.to_i : 0),
            "usable" => (b.pbCanChooseMove?(idx_battler, i, false) ? true : false) }
        end.compact
      end

      def party_options(scene, idx_battler)
        b = scene.instance_variable_get(:@battle)
        b.pbParty(idx_battler).each_with_index.map do |p, i|
          next nil unless p

          { "index" => i, "name" => p.name, "species" => p.species.to_s, "level" => p.level,
            "hp" => p.hp, "total_hp" => p.totalhp, "able" => p.able? ? true : false,
            "active" => (b.pbFindBattler(i, idx_battler) ? true : false) }
        end.compact
      end

      def target_options(scene, idx_battler, target_data)
        texts = scene.pbCreateTargetTexts(idx_battler, target_data)
        texts.each_with_index.map { |t, i| t.nil? ? nil : { "index" => i, "name" => t } }.compact
      end

      # --- the "battle" and "decide" verbs ------------------------------------

      def cmd_battle(id, rest)
        args = rest.split
        if args[0] == "mode"
          unless MODES.include?(args[1].to_s)
            return Autopilot.respond(id, "ok" => false, "error" => "mode is one of #{MODES.join('|')}")
          end

          self.mode = args[1]
        end
        Autopilot.respond(id, "ok" => true, "mode" => @mode.to_s, "battle" => snapshot)
      end

      # Answers when the engine asks the next question or the battle ends, so each
      # "decide" returns exactly when there is something new to look at.
      def cmd_decide(id, rest)
        ok, error = decide(rest)
        return Autopilot.respond(id, "ok" => false, "error" => error) unless ok

        asked = @serial
        Autopilot.start_job(id) do
          next false if attached? && !(@serial > asked && @awaiting)

          Autopilot.respond(id, "ok" => true, "accepted" => @result ? true : false,
                                "next" => @awaiting && @awaiting["kind"], "battle" => attached?)
        end
      end

      Autopilot.verb("battle") { |id, rest| cmd_battle(id, rest) }
      Autopilot.verb("decide") { |id, rest| cmd_decide(id, rest) }
    end
  end
end

if PEMK::Autopilot.active? && defined?(Battle::Scene)
  class Battle::Scene
    unless method_defined?(:pemk_ap_orig_pbCommandMenu)
      alias_method :pemk_ap_orig_pbStartBattle,          :pbStartBattle
      alias_method :pemk_ap_orig_pbEndBattle,            :pbEndBattle
      alias_method :pemk_ap_orig_pbCommandMenu,          :pbCommandMenu
      alias_method :pemk_ap_orig_pbFightMenu,            :pbFightMenu
      alias_method :pemk_ap_orig_pbChooseTarget,         :pbChooseTarget
      alias_method :pemk_ap_orig_pbPartyScreen,          :pbPartyScreen
      alias_method :pemk_ap_orig_pbItemMenu,             :pbItemMenu
      alias_method :pemk_ap_orig_pbShowCommands,         :pbShowCommands
      alias_method :pemk_ap_orig_pbForgetMove,           :pbForgetMove
      alias_method :pemk_ap_orig_pbNameEntry,            :pbNameEntry
      alias_method :pemk_ap_orig_pbShowPokedex,          :pbShowPokedex
      alias_method :pemk_ap_orig_pbDisplayMessage,       :pbDisplayMessage
      alias_method :pemk_ap_orig_pbDisplayPausedMessage, :pbDisplayPausedMessage

      def pbStartBattle(battle)
        PEMK::Autopilot::BattleControl.attach(self)
        pemk_ap_orig_pbStartBattle(battle)
      end

      def pbEndBattle(result)
        pemk_ap_orig_pbEndBattle(result)
      ensure
        PEMK::Autopilot::BattleControl.detach
      end

      def pbCommandMenu(idxBattler, firstAction)
        ctl = PEMK::Autopilot::BattleControl
        labels, values = ctl.command_point(self, idxBattler, firstAction)
        d = ctl.ask(self, "command", idxBattler, labels, values) { 0 }
        d == :keys ? pemk_ap_orig_pbCommandMenu(idxBattler, firstAction) : d
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      # The engine's block registers the move and answers whether it was taken (no
      # PP, a disabled move... are refused); a refusal asks again, like the UI does.
      def pbFightMenu(idxBattler, megaEvoPossible = false, &block)
        ctl = PEMK::Autopilot::BattleControl
        tried = []
        loop do
          opts = ctl.move_options(self, idxBattler)
          # The strongest move left, so that a battle ends: the first one could be a
          # status move used forever.
          d = ctl.ask(self, "fight", idxBattler, opts) do
            left = opts.select { |o| o["usable"] && !tried.include?(o["index"]) }
            pick = left.max_by { |o| [o["power"].to_i, -o["index"]] }
            pick ? pick["index"] : -1
          end
          return pemk_ap_orig_pbFightMenu(idxBattler, megaEvoPossible, &block) if d == :keys

          tried << d
          accepted = block.call(d)
          ctl.result!(accepted)
          break if accepted
        end
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      def pbChooseTarget(idxBattler, target_data, visibleSprites = nil)
        ctl = PEMK::Autopilot::BattleControl
        opts = ctl.target_options(self, idxBattler, target_data)
        d = ctl.ask(self, "target", idxBattler, opts) { pbFirstTarget(idxBattler, target_data) }
        return pemk_ap_orig_pbChooseTarget(idxBattler, target_data, visibleSprites) if d == :keys

        d == :cancel ? -1 : d
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      def pbPartyScreen(idxBattler, canCancel = false, mode = 0, &block)
        ctl = PEMK::Autopilot::BattleControl
        tried = []
        loop do
          opts = ctl.party_options(self, idxBattler)
          d = ctl.ask(self, "party", idxBattler, opts) do
            pick = opts.find { |o| o["able"] && !o["active"] && !tried.include?(o["index"]) }
            pick ? pick["index"] : :cancel
          end
          return pemk_ap_orig_pbPartyScreen(idxBattler, canCancel, mode, &block) if d == :keys
          return if d == :cancel && canCancel
          next if d == :cancel   # a forced switch cannot be cancelled: ask again

          tried << d
          accepted = block.call(d, PEMK::Autopilot::BattleControl::MessageSink)
          ctl.result!(accepted)
          break if accepted
        end
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      # "decide ITEM [target]": the use type comes from the item itself, and the
      # target defaults to the only foe (balls) or the Pokémon whose turn it is.
      def pbItemMenu(idxBattler, firstAction, &block)
        ctl = PEMK::Autopilot::BattleControl
        loop do
          d = ctl.ask(self, "item", idxBattler, []) { :cancel }
          return pemk_ap_orig_pbItemMenu(idxBattler, firstAction, &block) if d == :keys
          return if d == :cancel

          item, target = d
          data = GameData::Item.try_get(item)
          unless data && $bag.has?(item)
            PEMK::Autopilot::Observe.note("autopilot: no #{item} in the bag", "battle")
            ctl.result!(false)
            next
          end
          use = data.battle_use
          target ||= case use
                     when 4 then @battle.allOtherSideBattlers(idxBattler).first&.index
                     when 5 then idxBattler
                     else @battle.battlers[idxBattler].pokemonIndex
                     end
          accepted = block.call(data.id, use, target, -1, PEMK::Autopilot::BattleControl::MessageSink)
          ctl.result!(accepted)
          break if accepted
        end
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      def pbShowCommands(msg, commands, defaultValue)
        ctl = PEMK::Autopilot::BattleControl
        PEMK::Autopilot::Observe.note(msg, "battle")
        kind = commands.length == 2 && commands.map(&:to_s) == [_INTL("Yes"), _INTL("No")] ? "confirm" : "choice"
        d = ctl.ask(self, kind, nil, commands.map(&:to_s)) { 0 }
        d == :keys ? pemk_ap_orig_pbShowCommands(msg, commands, defaultValue) : d
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      def pbForgetMove(pkmn, moveToLearn)
        ctl = PEMK::Autopilot::BattleControl
        opts = pkmn.moves.each_with_index.map { |m, i| { "index" => i, "name" => m.name } }
        d = ctl.ask(self, "forget", nil, opts) { -1 }
        d == :keys ? pemk_ap_orig_pbForgetMove(pkmn, moveToLearn) : d
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      def pbNameEntry(helpText, pkmn)
        ctl = PEMK::Autopilot::BattleControl
        d = ctl.ask(self, "name", nil, [helpText.to_s]) { "" }
        d == :keys ? pemk_ap_orig_pbNameEntry(helpText, pkmn) : d
      ensure
        PEMK::Autopilot::BattleControl.done
      end

      # A screen that only waits for a key: skipped unless someone is at the keys.
      def pbShowPokedex(species)
        return pemk_ap_orig_pbShowPokedex(species) if PEMK::Autopilot::BattleControl.at_keys?

        PEMK::Autopilot::Observe.note("Pokédex entry for #{species} (skipped)", "battle")
      end

      def pbDisplayMessage(msg, brief = false, &block)
        PEMK::Autopilot::Observe.note(msg, "battle")
        pemk_ap_orig_pbDisplayMessage(msg, brief, &block)
      end

      # A paused message waits for a key at the end of a battle; with nobody at the
      # keys it would wait forever, so it closes on its own like a regular one.
      def pbDisplayPausedMessage(msg, &block)
        return pemk_ap_orig_pbDisplayPausedMessage(msg, &block) if PEMK::Autopilot::BattleControl.at_keys?

        PEMK::Autopilot::Observe.note(msg, "battle")
        pemk_ap_orig_pbDisplayMessage(msg, &block)
      end
    end
  end
end
