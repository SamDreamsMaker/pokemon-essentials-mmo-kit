# frozen_string_literal: true

require "sequel"

module PEMK
  module DB
    # One Sequel connection pool for the whole server. Pool size tracks the worker
    # count (a later milestone); 16 is the M1 default and matches the audit sizing.
    def self.connect(url, max_connections: 16)
      Sequel.connect(url, max_connections: max_connections)
    end
  end
end
