#===============================================================================
# PEMK :: Autopilot::Observe  (what the agent sees)
#-------------------------------------------------------------------------------
# A JSON-ready snapshot read straight from the game objects: scene, map, player,
# the message on screen, open command menus (choices and the highlighted index),
# the party, and whether the MMO layer is online. The agent reasons over this;
# screenshots are for evidence and for what the snapshot does not cover.
#
# The message and the menus are captured where the engine creates them
# (pbMessageDisplay, Window_DrawableCommand), which every message box and every
# command list in Essentials goes through.
#===============================================================================
module PEMK
  module Autopilot
    module Observe
      MAX_WINDOWS  = 16
      MAX_LOG      = 40
      FRESH_FRAMES = 3   # a menu not updated for longer is in the background

      MAX_SCREENS  = 8

      @messages = []   # texts on screen, innermost last (a choice can open over a message)
      @windows  = []   # command windows, newest last; disposed ones are pruned
      @log      = []   # recent messages, overworld and battle, oldest first
      @screens  = []   # full-screen UIs open over the map (party, bag, help...), innermost last

      module_function

      # $scene stays Scene_Map under the party screen, the bag, the controls help...;
      # these say which one is up.
      def screen_open(name)
        @screens.push(name)
        @screens.shift while @screens.size > MAX_SCREENS
      end

      def screen_closed(name)
        i = @screens.rindex(name)
        @screens.delete_at(i) if i
      end

      def screens
        @screens
      end

      def push_message(text)
        t = clean(text)
        @messages.push(t)
        note(t, "message")
      end

      # Every message that went by, so a line that closed on its own is not lost.
      def note(text, source)
        t = clean(text)
        return if t.empty?

        @log.push({ "frame" => PEMK::Autopilot.frame, "source" => source, "text" => t })
        @log.shift while @log.size > MAX_LOG
      end

      def log
        @log
      end

      def pop_message
        @messages.pop
      end

      def track_window(window)
        @windows.reject! { |w| gone?(w) }
        @windows.push(window)
        @windows.shift while @windows.size > MAX_WINDOWS
      end

      def snapshot
        s = { "frame" => PEMK::Autopilot.frame, "scene" => ($scene ? $scene.class.name : nil),
              "screens" => @screens.dup, "instance" => PEMK.instance, "online" => online,
              "flags" => temp_flags, "message" => @messages.last, "menus" => menus,
              "held" => VInput.held_names, "debug" => $DEBUG ? true : false }
        s["map"]     = map_info if $game_map
        s["player"]  = player_info if $game_player
        s["trainer"] = trainer_info if $player
        s["party"]   = party_info if $player
        s["remotes"] = remotes_info
        s["battle"]  = BattleControl.snapshot if defined?(BattleControl) && BattleControl.attached?
        s["text_entry"] = TextEntry.awaiting if defined?(TextEntry) && TextEntry.awaiting
        s["item_choice"] = ItemChoice.awaiting if defined?(ItemChoice) && ItemChoice.awaiting
        s["log"]     = @log.last(12)
        s
      end

      def online
        c = PEMK.client
        { "logged_in"  => (PEMK::Auth.logged_in? rescue false),
          "account_id" => (PEMK::Auth.account_id rescue nil),
          "connected"  => (c ? (c.connected? rescue false) : false) }
      end

      def temp_flags
        gt = $game_temp
        return {} unless gt

        { "in_menu"      => gt.in_menu ? true : false,
          "in_battle"    => gt.in_battle ? true : false,
          "message"      => gt.message_window_showing ? true : false,
          "transferring" => gt.player_transferring ? true : false,
          "event"        => ($game_map ? (pbMapInterpreterRunning? rescue false) : false),
          "encounter_type" => (gt.encounter_type rescue nil)&.to_s,   # left set by an encounter a Repel turned away
          "repel"        => ($PokemonGlobal ? ($PokemonGlobal.repel rescue nil) : nil) }
      end

      def current_message
        @messages.last
      end

      # Visible, active command lists that their loop is still updating, newest last:
      # what a key press would act on.
      def active_windows
        @windows.reject! { |w| gone?(w) }
        recent = PEMK::Autopilot.frame - FRESH_FRAMES
        @windows.select { |w| w.visible && w.active && w.instance_variable_get(:@pemk_ap_seen).to_i >= recent }
      rescue StandardError
        []
      end

      def menus
        active_windows.map do |w|
          cmds = w.respond_to?(:commands) ? Array(w.commands).map { |c| clean(c) } : nil
          { "class" => w.class.name, "commands" => cmds, "index" => w.index }
        end
      rescue StandardError
        []
      end

      def map_info
        { "id" => $game_map.map_id, "name" => clean($game_map.name) }
      rescue StandardError
        { "id" => ($game_map.map_id rescue nil) }
      end

      def player_info
        { "x" => $game_player.x, "y" => $game_player.y, "dir" => $game_player.direction,
          "moving" => $game_player.moving? ? true : false,
          "mode" => (PEMK::Presence.movement_mode.to_s rescue nil) }   # walk, run, bike, surf, dive
      end

      def trainer_info
        { "name" => $player.name, "money" => $player.money, "battle_points" => $player.battle_points,
          "badges" => ($player.badge_count rescue nil) }
      end

      def party_info
        $player.party.map do |p|
          { "species" => p.species.to_s, "name" => p.name, "level" => p.level, "hp" => p.hp,
            "total_hp" => p.totalhp, "fainted" => p.fainted? ? true : false,
            "uid" => (p.respond_to?(:pemk_uid) ? p.pemk_uid : nil) }
        end
      rescue StandardError
        []
      end

      # The other players this window draws on its map.
      def remotes_info
        return [] unless defined?(PEMK::Remotes) && PEMK::Remotes.players

        PEMK::Remotes.players.values.map do |rp|
          { "id" => rp.player_id, "name" => rp.player_name, "x" => rp.x, "y" => rp.y }
        end
      rescue StandardError
        []
      end

      def gone?(window)
        window.disposed?
      rescue StandardError
        true
      end

      # \v[n] shows a game variable; events park item ids there ("revive your
      # \v[1]"), which the engine prints by name.
      def variable_text(id)
        v = $game_variables ? $game_variables[id] : nil
        return v.to_s unless v.is_a?(Symbol)

        (GameData::Item.try_get(v)&.name rescue nil) || v.to_s
      end

      # The engine's codes without brackets. Only these are stripped: a greedy "\ and
      # letters" rule ate the first word of "\rHello" (the nurse's colour code).
      BARE_CODES = /\\(?:pog|pg|pm|cn|pt|wu|wm|wd|op|cl|r|b|g|1|\.|\||\^|!)/i

      # Message text without the engine's formatting codes (\c[1], \se[...], <b>...).
      def clean(text)
        t = text.to_s.dup
        t.gsub!(/\\pn/i) { $player ? $player.name.to_s : "" }
        t.gsub!(/\\v\[(\d+)\]/i) { variable_text($1.to_i) }
        t.gsub!(/\\n/i, " ")
        t.gsub!(/\\[a-z]+\[[^\]]*\]/i, "")
        t.gsub!(BARE_CODES, "")
        t.gsub!(/<[^>]*>/, "")
        t.gsub!(/[\x00-\x1f]/, " ")
        t.squeeze(" ").strip
      end
    end
  end
end

if PEMK::Autopilot.active?
  # Every message box goes through here; nested ones (a choice list over its prompt)
  # stack, and the ensure keeps the stack honest when a box is closed by a raise.
  if defined?(pbMessageDisplay) && !defined?(pemk_ap_orig_pbMessageDisplay)
    alias pemk_ap_orig_pbMessageDisplay pbMessageDisplay
    def pbMessageDisplay(msgwindow, message, letterbyletter = true, commandProc = nil, &block)
      PEMK::Autopilot::Observe.push_message(message)
      begin
        pemk_ap_orig_pbMessageDisplay(msgwindow, message, letterbyletter, commandProc, &block)
      ensure
        PEMK::Autopilot::Observe.pop_message
      end
    end
  end

  # Every command list (pause menu, choices, debug menu...) is a Window_DrawableCommand.
  # The one taking input is updated by its loop every frame; a menu left open in the
  # background (the debug menu behind the prompt its command opened) is not, which is
  # how "menus" tells them apart.
  if defined?(Window_DrawableCommand)
    class Window_DrawableCommand
      unless method_defined?(:pemk_ap_orig_initialize) || private_method_defined?(:pemk_ap_orig_initialize)
        alias_method :pemk_ap_orig_initialize, :initialize
        alias_method :pemk_ap_orig_update, :update

        # Fresh from birth: a choice list that has not been updated yet is already
        # waiting for an answer, and a tap in that frame would answer for the agent.
        def initialize(*args, &block)
          pemk_ap_orig_initialize(*args, &block)
          @pemk_ap_seen = PEMK::Autopilot.frame
          PEMK::Autopilot::Observe.track_window(self)
        end

        def update(*args, &block)
          pemk_ap_orig_update(*args, &block)
          @pemk_ap_seen = PEMK::Autopilot.frame
        end
      end
    end
  end

  # The full-screen UIs. Essentials' own convention is a *Scene class opened with
  # pbStartScene and closed with pbEndScene (party, bag, summary, Pokédex, storage,
  # marts...); the scripted ones (the controls help) are EventScenes run by main.
  # Wrapped where each method is defined, so subclasses are covered once.
  ObjectSpace.each_object(Class).select { |k| k.name.to_s.end_with?("Scene") }.each do |klass|
    next unless klass.method_defined?(:pbStartScene) && klass.method_defined?(:pbEndScene)
    next unless klass.instance_method(:pbStartScene).owner == klass
    next if klass.method_defined?(:pemk_ap_orig_pbStartScene)

    klass.class_eval do
      alias_method :pemk_ap_orig_pbStartScene, :pbStartScene
      alias_method :pemk_ap_orig_pbEndScene, :pbEndScene

      def pbStartScene(*args, &block)
        PEMK::Autopilot::Observe.screen_open(self.class.name)
        pemk_ap_orig_pbStartScene(*args, &block)
      end

      def pbEndScene(*args, &block)
        pemk_ap_orig_pbEndScene(*args, &block)
      ensure
        PEMK::Autopilot::Observe.screen_closed(self.class.name)
      end
    end
  end

  if defined?(EventScene) && !EventScene.method_defined?(:pemk_ap_orig_main)
    class EventScene
      alias_method :pemk_ap_orig_main, :main

      def main(*args, &block)
        PEMK::Autopilot::Observe.screen_open(self.class.name)
        pemk_ap_orig_main(*args, &block)
      ensure
        PEMK::Autopilot::Observe.screen_closed(self.class.name)
      end
    end
  end
end
