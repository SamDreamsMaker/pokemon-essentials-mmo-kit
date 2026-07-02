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
      state = PEMK::Auth.pending_state
      if state.is_a?(Hash) && !state.empty?
        # Returning account: the server copy is authoritative — load it and skip
        # the local menu (works even on a machine with no local save).
        #
        # Use pbCloseScene (plain sprite/viewport dispose), NOT pbEndScene:
        # pbEndScene runs a fade loop (pbFadeOutAndHide(@sprites) { pbUpdate })
        # that repeatedly drives Graphics.update from inside the load screen — that
        # is what intermittently blew mkxp-z's stack (SystemStackError on entry),
        # and is the same pbFadeOutAndHide that raised the MessageConfig each-for-nil.
        # pbCloseScene disposes without the fade, so both go away. Game.load fades
        # into the map itself anyway.
        (@scene.pbCloseScene rescue nil)
        Game.load(state)
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
