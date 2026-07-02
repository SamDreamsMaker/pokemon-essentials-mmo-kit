#!/usr/bin/env ruby
# frozen_string_literal: true

# Entry point for the PEMK dedicated server. Puts server/lib and the vendored
# protocol/ dir on the load path, then boots.
server_root = File.expand_path("..", __dir__)              # server/
$LOAD_PATH.unshift File.join(server_root, "lib")
$LOAD_PATH.unshift File.expand_path("../protocol", server_root)  # repo/protocol

require "pemk"

PEMK::Server.new.run
