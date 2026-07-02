#===============================================================================
# PEMK :: PersistHooks  (client side)
#-------------------------------------------------------------------------------
# Wires Phase 2 into the engine via aliases only (no core edits):
#   - PokemonLoadScreen#pbStartLoadScreen : run the blocking login first; if the
#     server already holds this account's state, load it directly (server is
#     authoritative) and skip the local new/continue menu.
#   - Game.start_new / Game.load : stamp the server identity onto $player after
#     the world is built.
#   - Game.save : after the normal local save, push the fresh save hash to the
#     server so the account's state survives a server restart.
#===============================================================================

# --- Blocking login at the New Game / Continue crossroads ---------------------
class PokemonLoadScreen
  unless method_defined?(:pokemmo_orig_pbStartLoadScreen)
    alias_method :pokemmo_orig_pbStartLoadScreen, :pbStartLoadScreen
    def pbStartLoadScreen
      PEMK::Auth.login_blocking
      # When we are logged in to the dedicated server, the server is the sole
      # source of truth: skip the local New Game / Continue screen entirely. Load
      # our server save if we have one, otherwise start a fresh game for this
      # account (the local Game.rxdata is unrelated to a server account and would
      # show as a misleading "Continue"). Only OFFLINE do we fall back to the
      # normal local load screen.
      if PEMK::Auth.logged_in?
        state = PEMK::Auth.pending_state
        # Use pbCloseScene (plain dispose), NOT pbEndScene: pbEndScene runs a fade
        # loop (pbFadeOutAndHide(@sprites) { pbUpdate }) that drives Graphics.update
        # from inside the load screen — the mkxp-z boot-stack hazard. Game.load /
        # Game.start_new do their own transition into the map anyway.
        (@scene.pbCloseScene rescue nil)
        if state.is_a?(Hash) && !state.empty?
          Game.load(state)         # returning account: hydrate the server save
        else
          Game.start_new           # new account: run the intro, no local "Continue"
        end
        return
      end
      pokemmo_orig_pbStartLoadScreen
    end
  end
end

# --- Identity stamping + server-side save push --------------------------------
module Game
  class << self
    unless method_defined?(:pokemmo_orig_start_new)
      alias_method :pokemmo_orig_start_new, :start_new
      alias_method :pokemmo_orig_load,      :load
      alias_method :pokemmo_orig_save,      :save

      def start_new
        pokemmo_orig_start_new
        PEMK::Auth.apply_identity
      end

      def load(save_data)
        pokemmo_orig_load(save_data)
        PEMK::Auth.apply_identity
        PEMK::Auth.clear_pending
      end

      def save(save_file = SaveData::FILE_PATH, safe: false)
        ok = pokemmo_orig_save(save_file, safe: safe)
        begin
          c = PEMK.client
          if ok && c && c.connected? && File.file?(save_file)
            # Push the save file's RAW bytes as an opaque body — the host stores
            # them verbatim and never Marshal.loads the save graph (no host RCE via
            # :save). We depend on no SaveData internals and don't even re-decode
            # our own save. The bytes are exactly what Game.load reads back.
            raw = File.binread(save_file)
            c.send_message({ :type => :save }, raw)
            PEMK.log("client: pushed save to server (#{raw.bytesize} bytes, opaque)")
          end
        rescue => e
          PEMK.log("client: save push failed: #{e.class}: #{e.message}")
        end
        ok
      end
    end
  end
end
