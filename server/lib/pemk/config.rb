# frozen_string_literal: true

require "yaml"

module PEMK
  # Boot configuration from ENV + config/economy_caps.yml. Fails FAST on a missing
  # economy cap (the audit flagged the old `rescue 999_999` silent default).
  class Config
    attr_reader :bind, :port, :database_url, :economy_caps, :badges_max, :inventory_caps,
                :monster_caps, :world_path, :position_enforcement, :pickup_enforce,
                :pickup_reset_allowed

    def initialize(env: ENV, root: File.expand_path("../..", __dir__))
      @bind         = env.fetch("PEMK_BIND", "127.0.0.1")
      @port         = Integer(env.fetch("PEMK_PORT", "9998"))
      @database_url = env.fetch("DATABASE_URL")

      # M4 Layer A: path to the build-time world export (server/data/world.json) the
      # WorldData model loads. Just a PATH here — a missing file is tolerated at boot
      # (audit no-ops); only a present-but-invalid file is a boot error (in WorldData).
      @world_path   = env.fetch("PEMK_WORLD", File.join(root, "data", "world.json"))

      # M4 Layer B enforcement mode: :off (detect+log only), :shadow (also log what a
      # snap-back WOULD do, correcting nothing), :on (actually snap-back). Default
      # :off — enforcement is opt-in and :shadow is the safe observe-first stage. An
      # unknown value falls back to :off rather than booting into a stricter mode.
      mode = env.fetch("PEMK_POS_ENFORCE", "off").to_s.strip.downcase
      @position_enforcement = %w[off shadow on].include?(mode) ? mode.to_sym : :off

      # M4 Layer C: server-minted item pickups. When on, an item-ball pickup must be
      # GRANTED by the server (validated existence + distance + one-shot) before the
      # client adds it. Binary + opt-in (default off); the mode is advertised to the
      # client in reconcile_block so the server is the single source of truth.
      @pickup_enforce = env.fetch("PEMK_PICKUP_ENFORCE", "off").to_s.strip.downcase == "on"

      # DEV/QA ONLY: allow a client-invoked pickup reset (forget this account's taken
      # tiles so item balls can be re-tested). Default off, and it MUST stay off in
      # production — with it on, any client could wipe its pickups and re-farm every
      # item ball infinitely. Advertised to the client (reconcile_block) so the F9 dev
      # tool only offers the reset when the server actually honors it.
      @pickup_reset_allowed = env.fetch("PEMK_ALLOW_PICKUP_RESET", "off").to_s.strip.downcase == "on"

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

      # M3.1 monster registry bounds (fail-fast; must land in the hash the handler
      # reads — the :badges nil-cap bug is the precedent).
      @monster_caps = {
        uid_req_max: require_cap(caps, "mon_uid_req_max"),
        party_max:   require_cap(caps, "mon_party_max"),
        level_max:   require_cap(caps, "mon_level_max"),
        trade_max:   require_cap(caps, "mon_trade_max")
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
