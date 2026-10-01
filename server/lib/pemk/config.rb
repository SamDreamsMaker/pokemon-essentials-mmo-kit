# frozen_string_literal: true

require "yaml"

module PEMK
  # Boot configuration from ENV + config/economy_caps.yml. Fails FAST on a missing
  # economy cap (the audit flagged the old `rescue 999_999` silent default).
  class Config
    PEER_CLASSES = %w[Pokemon Pokemon::Move Pokemon::Owner Mail].freeze
    attr_reader :bind, :port, :database_url, :economy_caps, :badges_max, :inventory_caps,
                :monster_caps, :world_path, :position_enforcement, :pickup_enforce,
                :pickup_reset_allowed, :battle_data_path, :battle_enforce_teams,
                :battle_enforce_encounters, :battle_enforce_catches, :battle_enforce_rewards,
                :battle_enforce_exp, :battle_enforce_rng, :corpus_retention_days,
                :battle_enforce_resim, :resim_min_strikes, :flag_state, :flag_enforce, :anomaly_detection,
                :gift_enforce, :peer_check, :peer_classes, :trade_redelivery, :item_record,
                :shop_enforce, :item_authority, :item_local, :item_grace, :money_authority,
                :money_payday_daily, :money_local_daily, :money_repeat_daily, :trainer_proof,
                :money_unproven_daily, :badge_authority, :badge_ignore

    def initialize(env: ENV, root: File.expand_path("../..", __dir__))
      @bind         = env.fetch("PEMK_BIND", "127.0.0.1")
      @port         = Integer(env.fetch("PEMK_PORT", "9998"))
      @database_url = env.fetch("DATABASE_URL")

      # M4 Layer A: path to the build-time world export (server/data/world.json) the
      # WorldData model loads. Just a PATH here — a missing file is tolerated at boot
      # (audit no-ops); only a present-but-invalid file is a boot error (in WorldData).
      @world_path   = env.fetch("PEMK_WORLD", File.join(root, "data", "world.json"))

      # M4 Layer D: path to the build-time battle-data export (server/data/battle_data.json)
      # the BattleData model loads (species/moves/items/types/natures/caps). Same policy as
      # the world path — absent is tolerated (Layer D no-ops), present-but-invalid is a boot
      # error (in BattleData).
      @battle_data_path = env.fetch("PEMK_BATTLE_DATA", File.join(root, "data", "battle_data.json"))

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

      # M4 Layer D: team/set legality enforcement mode, same off/shadow/on tri-state as
      # PEMK_POS_ENFORCE. Default off. D1 is detection-only (there is no battle-entry
      # gate yet), so every mode logs the illegal team; the mode sets the log label and
      # the future enforce hook. Unknown value -> off (never boot stricter than asked).
      tmode = env.fetch("PEMK_BATTLE_ENFORCE_TEAMS", "off").to_s.strip.downcase
      @battle_enforce_teams = %w[off shadow on].include?(tmode) ? tmode.to_sym : :off

      # M4 Layer D D2: server-authoritative wild encounters, same off/shadow/on tri-state.
      # off = local (no traffic); shadow = client reports its local encounter, server audits
      # it vs the tables + logs what it would mint; on = client requests the mint and adopts
      # it (server owns species/level/shiny/IVs). Default off. Unknown -> off.
      emode = env.fetch("PEMK_BATTLE_ENFORCE_ENCOUNTERS", "off").to_s.strip.downcase
      @battle_enforce_encounters = %w[off shadow on].include?(emode) ? emode.to_sym : :off

      # M4 Layer D D3: server-adjudicated Poké Ball captures, same tri-state. off = local;
      # shadow = client reports its local shake result, server logs what it would roll;
      # on = the SERVER rolls the shakes (client requests a verdict and adopts it). `on`
      # binds the catch to a stashed D2 encounter mint, so it effectively requires
      # PEMK_BATTLE_ENFORCE_ENCOUNTERS=on (a catch with no mint fail-opens to local).
      cmode = env.fetch("PEMK_BATTLE_ENFORCE_CATCHES", "off").to_s.strip.downcase
      @battle_enforce_catches = %w[off shadow on].include?(cmode) ? cmode.to_sym : :off

      # M4 Layer D D4: wild-battle reward bounds (EXP level-jumps + money deltas). off =
      # nothing; shadow/on both DETECT — a wild :battle_end opens a per-account budget
      # window, money deltas get "battle:<n>" ledger attribution (or "battle_suspect"),
      # and an impossible level jump is logged. Detection-only (Rare Candies level mons
      # outside battle → never rejects); `on` is reserved for a future hard gate. Default
      # off. Needs encounters=on for foe context (else it can't open windows).
      rmode = env.fetch("PEMK_BATTLE_ENFORCE_REWARDS", "off").to_s.strip.downcase
      @battle_enforce_rewards = %w[off shadow on].include?(rmode) ? rmode.to_sym : :off

      # M4 Layer D D5: statistical anomaly detection (cross-battle backstop). Binary — it
      # never enforces, it only accumulates per-account SUSPECT counters + a provenance
      # mix into a human review queue. Default off. NOTE it has no signal on its own: its
      # inputs come from the OTHER layers, so provenance needs encounters=on and the flag
      # counters need their source checks active (rewards!=off, encounters!=off). D5 alone
      # (everything else off) is inert.
      @anomaly_detection = env.fetch("PEMK_ANOMALY_DETECTION", "off").to_s.strip.downcase == "on"

      # M4 Layer D D6: per-mon EXP authority. off = nothing; shadow = the server tracks each
      # owned mon's EXP high-water from the party projection and flags a ROLLBACK (reported
      # EXP below the high-water = old save / edit), and logs the restore it WOULD send;
      # on = the :mon_ack additionally carries an UP-ONLY restore plan the client applies
      # (raise each below-high-water party mon back to the high-water — never lowers, so a
      # crash's earned-but-lost EXP is given back). Default off.
      xmode = env.fetch("PEMK_BATTLE_ENFORCE_EXP", "off").to_s.strip.downcase
      @battle_enforce_exp = %w[off shadow on].include?(xmode) ? xmode.to_sym : :off

      # M4 Layer D D7 part 1: the deterministic battle seam. off = nothing; shadow = the
      # client RECORDS wild battles under vanilla RNG (drawn values captured — the
      # harness-validation corpus); on = wild battles draw from server-seeded PCG32
      # streams (rolls DERIVED from the mint's seed, never trusted). Needs encounters=on
      # for the seed to ride the mint. INSTRUMENTATION, not enforcement — rejection is
      # D8's separate flag (PEMK_BATTLE_ENFORCE_RESIM). Default off.
      rmode = env.fetch("PEMK_BATTLE_ENFORCE_RNG", "off").to_s.strip.downcase
      @battle_enforce_rng = %w[off shadow on].include?(rmode) ? rmode.to_sym : :off

      # D7 part 3: battle-record corpus retention (days; matched records only —
      # evidence statuses are never auto-pruned). 0 = keep forever. Junk -> default
      # (30, mirrored in BattleRecords::RETENTION_DAYS — config loads first).
      raw = env.fetch("PEMK_CORPUS_RETENTION_DAYS", "").to_s.strip
      @corpus_retention_days = raw.match?(/\A\d+\z/) ? raw.to_i : 30

      # M4 Layer D D8: re-sim ENFORCEMENT — its OWN flag, per the operator contract
      # (an existing rng=on can never silently become enforcement). off = nothing;
      # shadow = the verdict sweep runs, logs + audits would_quarantine, changes no
      # state; on = seeded catches are born provisional (walk-gated trade hold,
      # fail-open TTL) and a walk-refuted catch auto-quarantines after MIN_STRIKES.
      # Requires rng=on to have any effect (seeds/records are its inputs).
      smode = env.fetch("PEMK_BATTLE_ENFORCE_RESIM", "off").to_s.strip.downcase
      @battle_enforce_resim = %w[off shadow on].include?(smode) ? smode.to_sym : :off

      # Distinct walk-refuted battles before quarantine arms for an account (aligned
      # with D5's drift-tolerant calibration; 1 = immediate, harsher).
      raw = env.fetch("PEMK_RESIM_MIN_STRIKES", "").to_s.strip
      @resim_min_strikes = raw.match?(/\A[1-9]\d*\z/) ? raw.to_i : 2

      # Sovereign variables. off = nothing; shadow = record the snapshot, fold the
      # delta stream into a mirror and measure the two against each other, granting
      # progression facts along the way; on = additionally MATERIALIZE those facts
      # into the client at login (a grant-only union, so it can restore progress but
      # never destroy any). Mirrored VALUES are held in session by PEMK_FLAG_ENFORCE.
      fmode = env.fetch("PEMK_FLAG_STATE", "off").to_s.strip.downcase
      @flag_state = %w[off shadow on].include?(fmode) ? fmode.to_sym : :off

      # Step 5: in-session enforcement over the owned values. off = nothing; shadow =
      # log what a repair WOULD restore when a snapshot disagrees with the mirror the
      # game's own writes built; on = keep the mirror and repair the client. Needs
      # PEMK_FLAG_STATE (the mirror only exists then), else it stays off.
      emode = env.fetch("PEMK_FLAG_ENFORCE", "off").to_s.strip.downcase
      @flag_enforce = %w[off shadow on].include?(emode) && @flag_state != :off ? emode.to_sym : :off

      # Step 6: the payout gate. off = gifts are reported after the fact (detection,
      # under PEMK_FLAG_STATE); shadow = the client asks before an event gives an item
      # and the server logs what it WOULD refuse, granting everything; on = a one-shot
      # gift the world export knows is paid once per account.
      gmode = env.fetch("PEMK_GIFT_ENFORCE", "off").to_s.strip.downcase
      @gift_enforce = %w[off shadow on].include?(gmode) ? gmode.to_sym : :off

      # A body one client sends another (a trade's escrow, a PvP team) is Marshal the
      # receiver loads. off = relayed as before; shadow = a body naming a class outside
      # the allow list is logged; on = it is dropped, and clients check it too before
      # loading. PEMK_PEER_CLASSES adds a game's own classes (comma-separated) to the
      # party's (Pokemon, Pokemon::Move, Pokemon::Owner, Mail).
      pcheck = env.fetch("PEMK_PEER_CHECK", "off").to_s.strip.downcase
      @peer_check = %w[off shadow on].include?(pcheck) ? pcheck.to_sym : :off
      extra = env.fetch("PEMK_PEER_CLASSES", "").to_s.split(",").map(&:strip).reject(&:empty?)
      @peer_classes = (PEER_CLASSES + extra).uniq.freeze

      # A traded Pokemon the receiver never saved (a crash, a lost result) is sent
      # again. On unless PEMK_TRADE_REDELIVERY=off; only clients that say they can
      # take one are sent one.
      @trade_redelivery = env.fetch("PEMK_TRADE_REDELIVERY", "on").to_s.strip.downcase != "off"

      # Item authority E0: the PC storage, the mailbox and held items come back at login
      # from the server's record, like the bag, instead of from the save (whose separate
      # channel let a crash duplicate a withdrawn or taken item). full by default (a dupe
      # fix, and only for clients that send those stores); bag = the bag alone, as before.
      @item_record = env.fetch("PEMK_ITEM_RECORD", "full").to_s.strip.downcase == "bag" ? :bag : :full

      # Item authority E3: Mart purchases and sales. off = the client decides alone;
      # shadow = it asks, the server judges the clerk's stock, the price and the money and
      # logs what it WOULD refuse, granting everything; on = the server refuses and moves
      # the money itself.
      smode = env.fetch("PEMK_SHOP_ENFORCE", "off").to_s.strip.downcase
      @shop_enforce = %w[off shadow on].include?(smode) ? smode.to_sym : :off

      # Item authority E2: an increase of an item the player possesses (bag, PC, mailbox,
      # held items together) takes a credit a source the server knows left: a pickup it
      # granted, a gift it paid, a purchase it made, a traded Pokemon's item. off =
      # nothing; shadow = an increase no credit covers is logged UNEXPLAINED and filed for
      # review, and the record adopts it. on is enforcement (E4); until it exists, on
      # runs as shadow.
      imode = env.fetch("PEMK_ITEM_AUTHORITY", "off").to_s.strip.downcase
      @item_authority = %w[off shadow on].include?(imode) ? imode.to_sym : :off
      # Items the game produces in ways the exports cannot see (a plugin's own code, an
      # event whose item is computed): recorded, never judged. Comma-separated ids.
      @item_local = env.fetch("PEMK_ITEM_LOCAL", "").to_s.split(",").map { |i| i.strip.upcase }.reject(&:empty?).freeze
      # How long an unexplained increase waits for its source before its verdict (seconds;
      # 10 to 3600, default 120). Shorter only for tests: a pickup's report comes after its
      # message closes.
      raw = env.fetch("PEMK_ITEM_GRACE_SEC", "").to_s.strip
      @item_grace = raw.match?(/\A\d+\z/) ? raw.to_i.clamp(10, 3600) : 120

      # Money authority M1: the prize a trainer battle pays is claimed, and judged against
      # the exports - each trainer placed where the player is, each battle paid once, the
      # amount within its bound. off = nothing; shadow = each claim is judged and logged,
      # the ledger unchanged. on is enforcement (M3); until it exists, on runs as shadow.
      mmode = env.fetch("PEMK_MONEY_AUTHORITY", "off").to_s.strip.downcase
      @money_authority = %w[off shadow on].include?(mmode) ? mmode.to_sym : :off
      # The Pay Day an account may be credited per day (dollars) until battle records prove
      # each use: a mint is handed out on request, so without them Pay Day is only bounded.
      # A number, or "none" for no allowance cap. Default 20000.
      raw = env.fetch("PEMK_MONEY_PAYDAY_DAILY", "").to_s.strip.downcase
      @money_payday_daily = if raw == "none" then nil
                            elsif raw.match?(/\A\d+\z/) then raw.to_i
                            else 20_000
                            end
      # What an account may sell per day of the items the server never judged (a local
      # tier: Pickup, mining...) and never sold it itself - money no source it owns
      # explains. A number, or "none" for no cap. Default 10000 (Sam, 2026-09-29).
      raw = env.fetch("PEMK_MONEY_LOCAL_DAILY", "").to_s.strip.downcase
      @money_local_daily = if raw == "none" then nil
                           elsif raw.match?(/\A\d+\z/) then raw.to_i
                           else 10_000
                           end
      # The prizes an account may be credited per day for the battles the game lets be
      # fought again (Champion Blue): a claim proves no fight until battle records do, so a
      # client could claim one every 20 minutes without fighting. A number, or "none".
      # Default 20000, as for Pay Day.
      raw = env.fetch("PEMK_MONEY_REPEAT_DAILY", "").to_s.strip.downcase
      @money_repeat_daily = if raw == "none" then nil
                            elsif raw.match?(/\A\d+\z/) then raw.to_i
                            else 20_000
                            end
      # Trainer proof (docs/TRAINER-PROOF-DESIGN.md): a trainer prize is paid on its
      # battle's replay. off = nothing; shadow = each claim naming its battle gets the
      # replay's verdict, logged; on = a claim is held until that verdict, and paid only on
      # a proven win - where money authority enforces and battle rng is on, else as shadow.
      pmode = env.fetch("PEMK_TRAINER_PROOF", "off").to_s.strip.downcase
      @trainer_proof = %w[off shadow on].include?(pmode) ? pmode.to_sym : :off
      # Under trainer proof `on`, what an account may be paid per day for the prizes no
      # replay can prove for a cause on the server's side (no seed handed out, a battle the
      # export cannot rebuild, a record the harness cannot replay) - Sam, 2026-09-29: held,
      # and paid from a small allowance. A number (0: never). Default 5000.
      raw = env.fetch("PEMK_MONEY_UNPROVEN_DAILY", "").to_s.strip
      @money_unproven_daily = raw.match?(/\A\d+\z/) ? raw.to_i : 5_000
      # Badge authority (docs/BADGE-AUTHORITY-DESIGN.md): a badge is the server's when its
      # battle's win is proven. off = nothing; shadow = each new badge a client reports is
      # judged and logged (explained / pending / would refuse) - and, with trainer proof,
      # the clients fight the battles that give one alone and wait longer for their seeds,
      # so those wins are proven by the time it owns them; on = the server owns them, where
      # trainer proof and money authority enforce and nothing keeps it from it - else as
      # shadow.
      bmode = env.fetch("PEMK_BADGE_AUTHORITY", "off").to_s.strip.downcase
      @badge_authority = %w[off shadow on].include?(bmode) ? bmode.to_sym : :off
      # The badge writes the operator says are not the game's - a debug helper the export
      # cannot tell apart: "map:event", "ce:N" or "file:line", comma-separated, of those the
      # export cannot read or that give a badge with no battle. Their badges are refused
      # like any no win explains, and they keep the server from owning nothing. Default none.
      @badge_ignore = env.fetch("PEMK_BADGE_IGNORE", "").split(",").map { |k| k.strip.sub(/\Ace:/i, "ce:") }
                         .reject(&:empty?).uniq.freeze

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
