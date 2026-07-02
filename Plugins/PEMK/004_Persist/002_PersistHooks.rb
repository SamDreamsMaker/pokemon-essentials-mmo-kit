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
        # We skipped the scene's pbStartScene, so it has no @viewport/@sprites to
        # dispose — only close it if it was actually started (guards the nil
        # @viewport in pbCloseScene). NOT pbEndScene: its fade loop drives
        # Graphics.update from the load screen (the mkxp-z boot-stack hazard).
        # Game.load / Game.start_new do their own transition into the map anyway.
        (@scene.pbCloseScene rescue nil) if @scene && (@scene.instance_variable_get(:@viewport) rescue nil)
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
        PEMK::Auth.reconcile_economy       # ledger snapshot (empty for a new account)
        # Server-authoritative: the local Game.rxdata is a disposable per-session
        # cache, so overwriting it is always fine. Clear begun_new_game so the core
        # skips its "a different game is already saved" warning on the next save.
        ($game_temp.begun_new_game = false) if $game_temp && PEMK::Auth.logged_in?
      end

      def load(save_data)
        pokemmo_orig_load(save_data)
        PEMK::Auth.apply_identity
        PEMK::Auth.reconcile_economy       # ledger is the economy authority, over the blob
        PEMK::Auth.clear_pending
      end

      def save(save_file = SaveData::FILE_PATH, safe: false)
        ok = pokemmo_orig_save(save_file, safe: safe)
        # An explicit save is a checkpoint: flush any pending primitive deltas, then
        # push the full opaque blob — throttled by content hash so an UNCHANGED file
        # is never re-sent (no more 90 KB on every save). The server stores the body
        # verbatim and never Marshal.loads it (no host RCE via :save).
        if ok
          (PEMK::Sync.flush_event(:save) rescue nil)
          (PEMK::Sync.push_blob(save_file, force: true) rescue nil)
        end
        ok
      end
    end
  end
end
