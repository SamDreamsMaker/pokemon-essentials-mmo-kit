# frozen_string_literal: true

# PEMK dedicated server — top-level require. Assumes the load path includes both
# server/lib and the vendored protocol/ dir (see bin/pemk_server.rb).
require "pemk_wire"        # PEMK::Wire (from protocol/)
require "pemk/config"
require "pemk/db"
require "pemk/password"
require "pemk/accounts"
require "pemk/sessions"
require "pemk/characters"
require "pemk/ledger"
require "pemk/inventory"
require "pemk/monsters"
require "pemk/trades"
require "pemk/world_data"
require "pemk/audit"
require "pemk/position_audit"
require "pemk/rate_limiter"
require "pemk/worker_pool"
require "pemk/player_mailbox"
require "pemk/reactor"
require "pemk/server"

module PEMK
  VERSION = "0.1.0-m1"
end
