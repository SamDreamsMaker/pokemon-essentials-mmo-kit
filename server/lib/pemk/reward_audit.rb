# frozen_string_literal: true

module PEMK
  # M4 Layer D D4: wild-battle reward WINDOWS. When the client reports a wild battle's
  # end (:battle_end — outcome + the foes it fought), a per-account budget window opens:
  # how much EXP the party could have legitimately gained (RewardCalc envelope) and how
  # much money could have moved (Pay Day gain / blackout loss). Subsequent money deltas
  # and level jumps are checked against — and consume — the window:
  #
  #   money  in-window & within budget  -> ledger reason "battle:<n>" (attribution)
  #          in-window but OVER budget  -> "battle_suspect:<n>" + a SUSPECT log
  #          no window                  -> "unattributed" (shops/trades are normal)
  #   levels jump needs more exp than the window holds -> SUSPECT log (detection-only;
  #          Rare Candies etc. legitimately level mons outside battles, so this NEVER
  #          rejects — it is telemetry with that caveat baked into the log label)
  #
  # ATTRIBUTION vs SUSPICION: money attribution (`battle:<n>` / `unattributed`) is written
  # to the append-only ledger, so it must stay CLEAN — a suspicious over-budget delta is
  # still attributed to its battle window and the *suspicion* is a returned flag the caller
  # LOGS (never a ledger label). A money DECREASE is a spend/loss, never a reward cheat, so
  # it is never suspect.
  #
  # THREADING: called from BOTH the reactor thread (record_battle, check_levels) and worker
  # threads (note_money, via the PlayerMailbox), so all @windows access is under @mutex.
  class RewardAudit
    WINDOW_TTL  = 90         # seconds a battle's budget stays consumable
    MAX_WINDOWS = 4_096      # stale-entry sweep threshold (accounts, not per-account)

    def initialize(reward_calc, battle_data, logger: nil)
      @calc    = reward_calc
      @bd      = battle_data
      @log     = logger || ->(_m) {}
      @windows = {}   # account_id => { id:, exp:, gain:, loss:, at: }
      @counter = 0
      @mutex   = Mutex.new
    end

    # A wild battle ended. Accumulate its budgets into the account's window (several
    # quick battles inside one TTL stack). foes: [{species:, level:}...] (<=2, already
    # validated by the handler). -> the window (for logging).
    def record_battle(account_id, foes, outcome, now: Time.now)
      @mutex.synchronize do
        w = window(account_id, now)
        if [1, 4].include?(outcome)   # won / caught: exp + Pay Day gains possible
          foes.each do |f|
            per_foe = @calc.max_exp_per_foe(f[:species], f[:level])
            w[:exp] += per_foe if per_foe
          end
          w[:gain] += @calc.wild_money_gain_max
        elsif [2, 5].include?(outcome)   # lost / draw: blackout money loss possible
          w[:loss] += @calc.wild_money_loss_max
        end
        w[:at] = now
        w.dup   # a copy for logging; never let the caller mutate the live window
      end
    end

    # A money delta arrived. -> [ledger_reason, suspect_bool]. The reason is always a CLEAN
    # attribution (`battle:<n>` / `unattributed`) safe to persist; suspect is a log-only
    # flag. Consumes budget. A negative delta (spend/blackout) is never suspect.
    def note_money(account_id, delta, now: Time.now)
      @mutex.synchronize do
        w = live_window(account_id, now)
        return ["unattributed", false] unless w && delta.is_a?(Integer) && delta != 0

        if delta.positive?
          if delta <= w[:gain]
            w[:gain] -= delta
            ["battle:#{w[:id]}", false]
          else
            w[:gain] = 0
            ["battle:#{w[:id]}", true]   # over the battle's yield -> attributed + SUSPECT (logged, not persisted)
          end
        elsif -delta <= w[:loss]
          w[:loss] += delta              # delta negative -> shrinks the loss budget
          ["battle:#{w[:id]}", false]
        else
          ["unattributed", false]        # a spend larger than the blackout cap: a normal purchase
        end
      end
    end

    # Party level jumps arrived (from the party projection). changes = [[species, old,
    # new], ...]. Sums the conservative min-exp each jump requires and consumes the exp
    # budget; anything beyond is suspect (detection-only). -> [suspect_bool, detail_str].
    def check_levels(account_id, changes, now: Time.now)
      need    = 0
      parts   = []
      unknown = false
      changes.each do |species, old_l, new_l|
        sp   = @bd.species(species.to_s)
        rate = sp && sp["growth_rate"]
        min  = rate && @calc.min_exp_for_jump(rate, old_l, new_l)
        if min.nil?
          unknown = true   # no curve/species -> that jump is unjudgeable, skip it
          next
        end
        need += min
        parts << "#{species} #{old_l}->#{new_l}(min #{min})"
      end
      return [false, nil] if need.zero?

      @mutex.synchronize do
        w      = live_window(account_id, now)
        budget = w ? w[:exp] : 0
        if need <= budget
          w[:exp] -= need if w
          [false, nil]
        else
          detail = "#{parts.join(', ')} needs >=#{need} exp vs window #{budget}" \
                   "#{unknown ? ' (+unjudgeable jumps skipped)' : ''}"
          [true, detail]
        end
      end
    end

    private
    # NOTE: window/live_window/sweep assume @mutex is already held (all public callers wrap).

    def window(account_id, now)
      sweep(now) if @windows.size > MAX_WINDOWS
      w = live_window(account_id, now)
      return w if w

      @counter += 1
      @windows[account_id] = { id: @counter, exp: 0, gain: 0, loss: 0, at: now }
    end

    def live_window(account_id, now)
      w = @windows[account_id]
      return nil unless w

      if now - w[:at] > WINDOW_TTL
        @windows.delete(account_id)
        nil
      else
        w
      end
    end

    def sweep(now)
      @windows.delete_if { |_k, w| now - w[:at] > WINDOW_TTL }
    end
  end
end
