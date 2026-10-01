#===============================================================================
# PEMK :: Autopilot::Actions  (verbs that act on what the agent sees)
#-------------------------------------------------------------------------------
#   wait_until COND[|COND...] [ARG] [within SECONDS]
#       idle, battle, no_battle, decision, message, no_message, menu, no_menu,
#       menu_with TEXT, map ID, scene NAME. Answers with the condition that matched.
#       "decision|no_battle" is the usual way to wait out a battle turn.
#   choose LABEL|INDEX
#       picks an entry of the newest open menu by its text (or index) and confirms
#       it, through the menu's own cursor and the USE key.
#   dismiss [MAX]
#       taps USE until no message is left (chained lines included), and stops early
#       when a choice list opens so the agent can pick.
#   advance on|off
#       windows that only wait for a key (level-up stats...) close on their own;
#       always on while a battle is played by the agent or the auto policy.
#   fast on|off
#       instant text, no battle animations, no nickname or switch prompts - for the
#       test window's own options; "off" puts the previous ones back.
#===============================================================================
module PEMK
  module Autopilot
    module Actions
      FAST_OPTIONS = { textspeed: 3, battlescene: 1, battlestyle: 1, givenicknames: 1, sendtoboxes: 1 }.freeze
      # In seconds, because the message box runs on the clock: it ignores USE while it
      # slides in, and a chained line opens a moment after the previous one closes.
      TAP_GAP = 0.12   # between two taps
      QUIET   = 0.25   # no message for this long = the chain of lines is over

      @saved_options = nil
      @advance       = false

      module_function

      def advance?
        Autopilot.driving? && (@advance || BattleControl.mode != :keys)
      end

      def advance=(on)
        @advance = on ? true : false
      end

      # --- conditions ---------------------------------------------------------

      def idle?
        gt = $game_temp
        return false unless $scene.is_a?(Scene_Map) && gt && $game_player

        !(gt.in_menu || gt.in_battle || gt.message_window_showing || gt.player_transferring ||
          $game_player.moving? || (pbMapInterpreterRunning? rescue false) || !Observe.menus.empty? ||
          !Observe.screens.empty? || TextEntry.awaiting || ItemChoice.awaiting)
      end

      def condition(name, arg)
        case name
        when "idle"       then idle?
        when "battle"     then BattleControl.attached?
        when "no_battle"  then !BattleControl.attached?
        when "decision"   then !BattleControl.awaiting.nil?
        when "message"    then !Observe.current_message.nil?
        when "no_message" then Observe.current_message.nil?
        when "menu"       then !Observe.menus.empty?
        when "no_menu"    then Observe.menus.empty?
        when "menu_with"  then menu_with?(arg)
        when "text"       then !TextEntry.awaiting.nil?
        when "item"       then !ItemChoice.awaiting.nil?
        when "map"        then $game_map && $game_map.map_id == arg.to_i
        when "scene"      then $scene && $scene.class.name == arg.to_s
        end
      end

      def menu_with?(text)
        want = text.to_s.downcase
        Observe.menus.any? { |m| Array(m["commands"]).any? { |c| c.to_s.downcase.start_with?(want) } }
      end

      TAKES_ARG = %w[map scene menu_with].freeze
      KNOWN     = %w[idle battle no_battle decision message no_message menu no_menu menu_with text item
                     map scene].freeze

      def cmd_wait_until(id, rest)
        words  = rest.split
        limit  = JOB_SECONDS
        if (i = words.index("within"))
          limit = words[i + 1].to_f.clamp(0.1, 3600.0)
          words.slice!(i, 2)
        end
        conds = words[0].to_s.split("|")
        arg   = words[1..].join(" ")
        unknown = conds.reject { |c| KNOWN.include?(c) }
        unless !conds.empty? && unknown.empty?
          return Autopilot.respond(id, "ok" => false, "error" => "unknown condition #{unknown.first.inspect}; " \
                                                                  "one of #{KNOWN.join(', ')}")
        end

        start = Autopilot.frame
        Autopilot.start_job(id, limit) do
          hit = conds.find { |c| condition(c, TAKES_ARG.include?(c) ? arg : nil) }
          next false unless hit

          Autopilot.respond(id, "ok" => true, "matched" => hit, "waited" => Autopilot.frame - start)
        end
      end

      # --- menus ----------------------------------------------------------------

      def cmd_choose(id, rest)
        wanted = rest.strip
        window = Observe.active_windows.last
        return Autopilot.respond(id, "ok" => false, "error" => "no menu is open") unless window

        labels = window.respond_to?(:commands) ? Array(window.commands).map { |c| Observe.clean(c) } : []
        index  = if wanted.match?(/\A\d+\z/) then wanted.to_i
                 else labels.index { |l| l.casecmp?(wanted) } ||
                      labels.index { |l| l.downcase.start_with?(wanted.downcase) }
                 end
        unless index && index < [labels.length, 1].max
          return Autopilot.respond(id, "ok" => false, "error" => "no entry #{wanted.inspect}", "commands" => labels)
        end

        window.index = index
        use = VInput.key("USE")
        VInput.hold(use, 2)
        settled = nil
        Autopilot.start_job(id) do
          next false if VInput.down?(use)

          settled ||= Autopilot.frame
          next false if Autopilot.frame == settled

          Autopilot.respond(id, "ok" => true, "chose" => labels[index] || index)
        end
      end

      # --- messages -------------------------------------------------------------

      # The real bound is the command's time budget; the tap count only guards a box
      # that never closes. It is generous because a line with a jingle
      # ("obtained Omanyte!", \wtnp[80]) ignores USE for seconds.
      def cmd_dismiss(id, rest)
        max       = rest.to_i.positive? ? rest.to_i : 200
        use       = VInput.key("USE")
        presses   = 0
        last_tap  = nil
        quiet_at  = nil
        screen_at = nil
        Autopilot.start_job(id) do
          next false if VInput.down?(use)

          # Anything the agent has to act on ends the run of taps: tapping on would
          # answer for it (a menu) or wait on something taps cannot give (text). A
          # screen gets a moment first: the pause menu closes on its own once the
          # line it showed has been read.
          stop = needs_the_agent
          if stop == "screen"
            screen_at ||= Autopilot.now
            next false if Autopilot.now - screen_at < QUIET
          else
            screen_at = nil
          end
          if stop
            next Autopilot.respond(id, "ok" => true, "presses" => presses, "stopped" => stop,
                                       "message" => Observe.current_message, "menus" => Observe.menus)
          end
          if Observe.current_message.nil?
            # An event still running is mid-conversation (the nurse's healing jingle
            # sits between two lines), not done.
            if (pbMapInterpreterRunning? rescue false)
              quiet_at = nil
              next false
            end
            quiet_at ||= Autopilot.now
            next false if Autopilot.now - quiet_at < QUIET

            next Autopilot.respond(id, "ok" => true, "presses" => presses)
          end
          quiet_at = nil
          next false if last_tap && Autopilot.now - last_tap < TAP_GAP
          if presses >= max
            next Autopilot.respond(id, "ok" => false, "error" => "message still open after #{max} presses",
                                       "message" => Observe.current_message)
          end
          VInput.hold(use, 2)
          presses += 1
          last_tap = Autopilot.now
          false
        end
      end

      # -> what the agent must handle next, or nil when taps can carry on. A screen
      # with a message over it ("Trade request sent...", shown from the pause menu)
      # is waiting on that message, which taps close.
      def needs_the_agent
        return "menu"   unless Observe.menus.empty?
        return "text"   if TextEntry.awaiting
        return "item"   if ItemChoice.awaiting
        return "battle" if BattleControl.attached?
        return "screen" if Observe.current_message.nil? && !Observe.screens.empty?

        nil
      end

      def cmd_advance(id, rest)
        @advance = rest.strip != "off"
        Autopilot.respond(id, "ok" => true, "advance" => @advance)
      end

      # --- speed ----------------------------------------------------------------

      def cmd_fast(id, rest)
        sys = $PokemonSystem
        return Autopilot.respond(id, "ok" => false, "error" => "no game loaded yet") unless sys

        if rest.strip == "off"
          (@saved_options || {}).each { |k, v| sys.send("#{k}=", v) }
          @saved_options = nil
        else
          @saved_options ||= FAST_OPTIONS.keys.to_h { |k| [k, sys.send(k)] }
          FAST_OPTIONS.each { |k, v| sys.send("#{k}=", v) }
        end
        (MessageConfig.pbSetTextSpeed(MessageConfig.pbSettingToTextSpeed(sys.textspeed)) rescue nil)
        Autopilot.respond(id, "ok" => true, "fast" => !@saved_options.nil?)
      end

      Autopilot.verb("wait_until") { |id, rest| cmd_wait_until(id, rest) }
      Autopilot.verb("choose")     { |id, rest| cmd_choose(id, rest) }
      Autopilot.verb("dismiss")    { |id, rest| cmd_dismiss(id, rest) }
      Autopilot.verb("advance")    { |id, rest| cmd_advance(id, rest) }
      Autopilot.verb("fast")       { |id, rest| cmd_fast(id, rest) }
    end

    # Text the engine asks for (player name, nicknames, the PEMK login). Its entry
    # screens need real typing, which virtual keys cannot give, so an autopilot window
    # takes the text from "type TEXT" instead: queued ahead of the prompt, or answered
    # while it waits. The prompt shows in "state" as text_entry; the text itself is
    # never logged (passwords go through here).
    module TextEntry
      @queued   = nil
      @awaiting = nil
      @answer   = nil

      module_function

      def awaiting
        @awaiting
      end

      def ask(prompt, min, max, initial, secret = false)
        Observe.note(prompt, "text")
        if @queued
          text = @queued
          @queued = nil
          return text[0, max]
        end
        @awaiting = { "prompt" => Observe.clean(prompt), "min" => min, "max" => max,
                      "initial" => (secret ? "" : initial.to_s), "secret" => secret ? true : false }
        @answer = nil
        loop do
          Graphics.update   # the autopilot tick answers "type" from in here
          Input.update
          break unless @answer.nil?
        end
        text = @answer
        @answer = nil
        text[0, max]
      ensure
        @awaiting = nil
      end

      def cmd_type(id, rest)
        if @awaiting
          @answer = rest
          Autopilot.respond(id, "ok" => true, "answered" => @awaiting["prompt"])
        else
          @queued = rest
          Autopilot.respond(id, "ok" => true, "queued" => true)
        end
      end

      Autopilot.verb("type") { |id, rest| cmd_type(id, rest) }
    end

    # An item the engine asks the player to choose from the bag (pbChooseItem,
    # pbChooseFossil, pbChooseApricorn - all end in PokemonBagScreen#
    # pbChooseItemScreen). The bag UI is skipped: "pick ITEM" answers with an item
    # the bag holds and the filter allows, "pick cancel" backs out. The choice shows
    # in "state" as item_choice, with the items that would be listed.
    module ItemChoice
      @queued   = nil
      @awaiting = nil
      @answer   = nil

      module_function

      def awaiting
        @awaiting
      end

      def allowed(bag, filter)
        slots = bag.pockets.compact.flatten(1).compact
        slots.map(&:first).uniq.select { |item| filter.nil? || filter.call(item) }
      rescue StandardError
        []
      end

      # -> the chosen item id, or nil for cancel.
      def ask(bag, filter)
        items = allowed(bag, filter)
        if @queued
          pick = @queued
          @queued = nil
          return resolve(pick, items)
        end
        @awaiting = { "allowed" => items.first(50).map(&:to_s) }
        @answer = nil
        loop do
          Graphics.update
          Input.update
          break unless @answer.nil?
        end
        pick = @answer
        @answer = nil
        resolve(pick, items)
      ensure
        @awaiting = nil
      end

      def resolve(pick, items)
        return nil if pick == :cancel

        items.find { |i| i.to_s.casecmp?(pick.to_s) }
      end

      def cmd_pick(id, rest)
        word = rest.strip
        pick = word.casecmp?("cancel") ? :cancel : word.upcase
        if @awaiting
          allowed = @awaiting["allowed"]
          unless pick == :cancel || allowed.include?(pick)
            return Autopilot.respond(id, "ok" => false, "error" => "#{word} is not on offer", "allowed" => allowed)
          end

          @answer = pick
          Autopilot.respond(id, "ok" => true, "picked" => pick.to_s)
        else
          @queued = pick
          Autopilot.respond(id, "ok" => true, "queued" => true)
        end
      end

      Autopilot.verb("pick") { |id, rest| cmd_pick(id, rest) }
    end
  end
end

if PEMK::Autopilot.active? && defined?(PokemonBagScreen) &&
   !PokemonBagScreen.method_defined?(:pemk_ap_orig_pbChooseItemScreen)
  class PokemonBagScreen
    alias_method :pemk_ap_orig_pbChooseItemScreen, :pbChooseItemScreen

    def pbChooseItemScreen(proc = nil)
      return pemk_ap_orig_pbChooseItemScreen(proc) unless PEMK::Autopilot.driving?

      PEMK::Autopilot::ItemChoice.ask(@bag, proc)
    end
  end
end

# A Mart's sell screen chooses from the bag scene itself, not the bag screen above.
if PEMK::Autopilot.active? && defined?(PokemonMart_Scene) &&
   !PokemonMart_Scene.method_defined?(:pemk_ap_orig_pbChooseSellItem)
  class PokemonMart_Scene
    alias_method :pemk_ap_orig_pbChooseSellItem, :pbChooseSellItem

    def pbChooseSellItem
      return pemk_ap_orig_pbChooseSellItem unless @subscene && $bag && PEMK::Autopilot.driving?

      PEMK::Autopilot::ItemChoice.ask($bag, nil)
    end
  end
end

if PEMK::Autopilot.active?
  if defined?(pbEnterText) && !defined?(pemk_ap_orig_pbEnterText)
    alias pemk_ap_orig_pbEnterText pbEnterText
    def pbEnterText(helptext, minlength, maxlength, initialText = "", mode = 0, pokemon = nil, nofadeout = false)
      unless PEMK::Autopilot.driving?
        return pemk_ap_orig_pbEnterText(helptext, minlength, maxlength, initialText, mode, pokemon, nofadeout)
      end

      PEMK::Autopilot::TextEntry.ask(helptext, minlength, maxlength, initialText)
    end
  end

  if defined?(pbMessageFreeText) && !defined?(pemk_ap_orig_pbMessageFreeText)
    alias pemk_ap_orig_pbMessageFreeText pbMessageFreeText
    def pbMessageFreeText(message, currenttext, passwordbox, maxlength, width = 240)
      return pemk_ap_orig_pbMessageFreeText(message, currenttext, passwordbox, maxlength, width) unless PEMK::Autopilot.driving?

      PEMK::Autopilot::TextEntry.ask(message, 0, maxlength, currenttext, passwordbox)
    end
  end
end

if PEMK::Autopilot.active?
  # Windows that only wait for USE (level-up stats in battle, rare candies...). Their
  # text goes to the log either way; with nobody at the keys they close at once.
  if defined?(pbTopRightWindow) && !defined?(pemk_ap_orig_pbTopRightWindow)
    alias pemk_ap_orig_pbTopRightWindow pbTopRightWindow
    def pbTopRightWindow(text, scene = nil)
      PEMK::Autopilot::Observe.note(text, "window")
      PEMK::Autopilot::VInput.tap(PEMK::Autopilot::VInput.key("USE")) if PEMK::Autopilot::Actions.advance?
      pemk_ap_orig_pbTopRightWindow(text, scene)
    end
  end
end
