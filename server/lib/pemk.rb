# frozen_string_literal: true

# PEMK dedicated server — top-level require. Assumes the load path includes both
# server/lib and the vendored protocol/ dir (see bin/pemk_server.rb).
require "pemk_wire"        # PEMK::Wire (from protocol/)
require "pemk/config"
require "pemk/db"
require "pemk/reactor"
require "pemk/server"

module PEMK
  VERSION = "0.1.0-m1"
end
