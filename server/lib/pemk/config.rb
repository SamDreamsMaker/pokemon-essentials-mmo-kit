# frozen_string_literal: true

require "yaml"

module PEMK
  # Boot configuration from ENV + config/economy_caps.yml. Fails FAST on a missing
  # economy cap (the audit flagged the old `rescue 999_999` silent default).
  class Config
    attr_reader :bind, :port, :database_url, :economy_caps, :badges_max, :inventory_caps

    def initialize(env: ENV, root: File.expand_path("../..", __dir__))
      @bind         = env.fetch("PEMK_BIND", "127.0.0.1")
      @port         = Integer(env.fetch("PEMK_PORT", "9998"))
      @database_url = env.fetch("DATABASE_URL")

      caps = YAML.safe_load_file(File.join(root, "config", "economy_caps.yml"))
      @economy_caps = {
        money:         require_cap(caps, "money"),
        coins:         require_cap(caps, "coins"),
        battle_points: require_cap(caps, "battle_points"),
        soot:          require_cap(caps, "soot")
      }
      @badges_max = require_cap(caps, "badges_max")
      # Badges ride the economy ledger as ONE bitmask field (:badges, bit i = badge
      # index i owned). Derive its cap from the single source of truth so the range
      # can never drift out of the signed-bigint column: all 63 bits set == (1<<63)-1
      # == INT64 max. This MUST land in the hash the Ledger reads (@economy_caps),
      # not just the YAML — otherwise apply_econ's `cap = @caps[:badges]` is nil and
      # every :badges frame is rejected :bad_field (silent no-op).
      @economy_caps[:badges] = (1 << @badges_max) - 1

      # M2.3 bag-inventory structural bounds (fail-fast, no silent rescue-default —
      # the headless server has no game Settings to fall back on).
      @inventory_caps = {
        per_item: require_cap(caps, "inv_max_per_item"),
        distinct: require_cap(caps, "inv_max_distinct"),
        total:    require_cap(caps, "inv_max_total")
      }
    end

    private

    def require_cap(caps, key)
      value = caps.is_a?(Hash) ? caps[key] : nil
      unless value.is_a?(Integer) && value.positive?
        raise "economy cap '#{key}' missing/invalid in config/economy_caps.yml"
      end

      value
    end
  end
end
