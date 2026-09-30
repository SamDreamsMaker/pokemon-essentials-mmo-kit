# frozen_string_literal: true

# M4 Layer D D7 part 2 — the corpus replay runner. A DEDICATED process (never the
# live server): boots the headless engine once, replays pending battle_records
# against it, and stamps replay_status = match | mismatch | error.
#
# Usage (WSL):
#   DATABASE_URL=postgres://... bundle exec ruby bin/pemk_replay.rb
# Env knobs:
#   PEMK_GAME_ROOT   game repo root (default: the server dir's parent)
#   REPLAY_LIMIT     max records per run (default 100)
#   REPLAY_ID        replay exactly one record id
#   REPLAY_DRY       "on" -> print verdicts, do not update rows

server_root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(server_root, "lib"))
$LOAD_PATH.unshift(File.expand_path("../protocol", server_root))

require "sequel"
require "timeout"
require "tmpdir"
require "pemk_wire"
require "pemk_prng"
require "pemk/proof_checks"
require "pemk/battle_data"
require "pemk/team_audit"
require_relative "../harness/harness"

game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", server_root)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
files = PEMK::Harness.boot!(game_root: game_root)
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts format("harness: engine booted (%d files, %.2fs)", files, t1 - t0)

db  = Sequel.connect(ENV.fetch("DATABASE_URL"))
dry = ENV["REPLAY_DRY"].to_s.downcase == "on"
# Trainer proof: what a player's Pokemon may be (its species line, a legal set) - D1's
# checks on the game's battle data, as the live server loads it.
bd_path = ENV["PEMK_BATTLE_DATA"] || File.join(server_root, "data", "battle_data.json")
battle_data = (PEMK::BattleData.new(bd_path) rescue nil)
$audit = battle_data&.loaded? ? PEMK::TeamAudit.new(battle_data) : nil
puts "replay: no battle data at #{bd_path} - trainer teams checked without it" unless $audit

# Replayable statuses only. walk_mismatch / no_log / mode_mismatch are TRIAGE
# evidence — never silently overwritten; REPLAY_ID alone still respects that
# (REPLAY_FORCE=on to override, e.g. after a triage decision). The harness may
# only transition pending|walk_ok|walk_skipped -> match|mismatch|error|
# not_replayable (the replay_status state machine documented in migration 013).
REPLAYABLE = %w[pending walk_ok walk_skipped].freeze
STATUS = { match: "match", mismatch: "mismatch", error: "error", skipped: "not_replayable" }.freeze

REPLAY_SEC = 20         # one replay takes milliseconds; a record that holds the tool longer is not replayed
OTHER_PER_PASS = 100    # records not a trainer battle's won one, per pass: a prize waits at most one short pass
# The record being replayed, on disk: one the tool died on (no Ruby error to catch - a
# stack overflow, a kill) is an error at the next boot, never replayed first again. A
# database away is no death: the mark goes, the record waits for the next pass.
MARK = ENV["PEMK_REPLAY_MARK"] || File.join(Dir.tmpdir, "pemk_replay.current")

def safe_text(value) = PEMK::ProofChecks.safe_text(value)

def mark!(id) = File.write(MARK, id.to_s)
def unmark! = (File.delete(MARK) if File.exist?(MARK))

# At boot: the record the tool died replaying took it down - an error now.
def clear_replaying(db)
  return unless File.exist?(MARK)

  id = File.read(MARK).to_i
  n = db[:battle_records].where(id: id, replay_status: REPLAYABLE)
                         .update(replay_status: "error", verdict_at: Time.now,
                                 replay_detail: "the replay tool died replaying this record")
  puts "replay: record ##{id} took the tool down - marked as an error" if n.positive?
  unmark!
end

# Tests make the tool fail on one record: REPLAY_FAULT_ID names it, REPLAY_FAULT the way
# (a Ruby error by default; db: the database away; die: the tool dies mid-replay).
def fault!(row)
  return unless ENV["REPLAY_FAULT_ID"].to_i == row[:id]

  case ENV["REPLAY_FAULT"]
  when "db"  then raise Sequel::DatabaseDisconnectError, "a fault injected: the database away"
  when "die" then raise SystemStackError, "a fault injected: the tool dies"
  else raise "a fault injected for record #{row[:id]}"
  end
end

# One pass over the queue. -> tally hash (also the loop's liveness signal).
def replay_pass(db, dry:, limit:)
  ds =
    if ENV["REPLAY_ID"]
      one = db[:battle_records].where(id: ENV["REPLAY_ID"].to_i)
      ENV["REPLAY_FORCE"].to_s.downcase == "on" ? one : one.where(replay_status: REPLAYABLE)
    else
      db[:battle_records].where(replay_status: REPLAYABLE)
    end
  # A trainer battle's won record first - a prize waits on it -, then a few of the rest:
  # no queue of other records holds a prize back.
  rows = ds.exclude(trainer_battle_id: nil).where(outcome: 1).order(:id).limit(limit).all
  if rows.size < limit
    rows += ds.exclude(id: rows.map { |r| r[:id] })
              .order(Sequel.case({ { trainer_battle_id: nil } => 1 }, 0), :id)
              .limit([limit - rows.size, OTHER_PER_PASS].min).all
  end
  tally = Hash.new(0)
  rows.each do |row|
    verdict =
      begin
        replay_row(db, row, dry: dry)
      rescue Sequel::DatabaseError, Sequel::PoolTimeout
        unmark!
        raise   # the database, not the record: the pass stops, the record waits for the next one
      rescue StandardError => e
        # Never the record that broke the tool again: an error (its prize unprovable).
        puts "  ##{row[:id]}: the replay tool failed on it (#{e.class})"
        unless dry
          db[:battle_records].where(id: row[:id])
            .update(replay_status: "error", verdict_at: Time.now,
                    replay_detail: "the replay tool failed on this record (#{e.class})")
        end
        :error
      end
    unmark!   # done with it (a death skips this: the mark stays for the next boot)
    tally[verdict] += 1
  end
  tally
end

# Trainer proof P4: the seed row a trainer record is replayed on - the one it is bound
# to, or (a record a verdict let go of, replayed again) the account's row of its seed.
def seed_row_of(db, row, rec)
  return db[:trainer_battles].where(id: row[:trainer_battle_id]).first if row[:trainer_battle_id]
  return nil unless rec[:kind] == "trainer" && row[:battle_seed]

  db[:trainer_battles].where(account_id: row[:account_id], seed: row[:battle_seed]).first
end

# -> the verdict stored for +row+.
def replay_row(db, row, dry:)
  rec = PEMK::Wire.decode_primitive(row[:record].to_s)
  result = nil
  # Trainer proof P4: a record bound to a seed row is replayed on that row's seed and
  # against its trainer, whatever its body says; its team first judged whole.
  if rec.is_a?(Hash) && (seed_row = seed_row_of(db, row, rec))
    rec, why = PEMK::ProofChecks.bind_to_seed(rec, row[:battle_seed], seed_row)
    why ||= PEMK::ProofChecks.team_shape(rec)
    result = { verdict: :mismatch, detail: why } if why
  end
  mark!(row[:id]) unless dry || result
  fault!(row)   # tests only (REPLAY_FAULT_ID)
  result ||=
    if rec.is_a?(Hash)
      Timeout.timeout(REPLAY_SEC) { PEMK::Harness.replay(rec) }
    else
      { verdict: :error, detail: "record body undecodable" }
    end
  # Trainer proof P3: a trainer battle's player team must be the server's own (owned,
  # locked, no more EXP than seen) - the replay alone takes the record's word for it.
  team, team_why = rec.is_a?(Hash) && rec[:kind] == "trainer" ? PEMK::ProofChecks.player_team(db, row[:account_id], rec, audit: $audit) : nil
  result[:detail] ||= team_why if team && team != :ok
  detail = safe_text(result[:detail])
  # verdict_at stamps EVERY pass (the live server's harness-liveness detector
  # reads it); the state machine only lets us land the four terminal statuses.
  db[:battle_records].where(id: row[:id])
     .update(replay_status: STATUS.fetch(result[:verdict]), verdict_at: Time.now,
             replay_prize: result[:prize].is_a?(Integer) ? result[:prize] : nil, replay_detail: detail,
             team_check: team&.to_s) unless dry
  detail = [detail, "team #{team}"].compact.join(" - ") if team && team != :ok
  line = "  ##{row[:id]} #{row[:mode]} outcome=#{row[:outcome]} rounds=#{row[:rounds]}: #{result[:verdict].to_s.upcase}"
  line += " — #{detail}" if detail
  line += " (prize #{result[:prize]})" if result[:prize]   # a trainer battle: what the engine paid
  puts line
  result[:verdict]
end

clear_replaying(db) unless dry

# PEMK_REPLAY_LOOP=<seconds>: the DAEMON form — boot the engine ONCE (the 1.7s
# amortizes), then poll the queue on the interval. This is what a real operator
# runs (a compose service / systemd unit); cron re-boots every run instead.
loop_secs = ENV["PEMK_REPLAY_LOOP"].to_s.strip
if loop_secs.match?(/\A[1-9]\d*\z/)
  interval = loop_secs.to_i
  puts "replay: LOOP mode — polling every #{interval}s (Ctrl-C to stop)"
  trap("INT")  { puts "\nreplay: stopping"; exit 0 }
  trap("TERM") { exit 0 }
  loop do
    begin
      t = replay_pass(db, dry: dry, limit: (ENV["REPLAY_LIMIT"] || 500).to_i)
      puts format("replay: pass — %d match / %d mismatch / %d error / %d skipped",
                  t[:match], t[:mismatch], t[:error], t[:skipped]) if t.values.sum.positive?
    rescue StandardError => e
      # the database away a moment: the daemon stays up, and tries again next time
      puts "replay: pass failed (#{e.class}: #{safe_text(e.message)})"
    end
    # Trainer proof P3: the server NOTIFYs each record it ingests - a trainer's prize
    # waits on this replay, so it runs within a second, not at the next poll.
    begin
      db.listen("pemk_replay", timeout: interval)
    rescue StandardError
      sleep interval
    end
  end
end

# One-shot mode (cron / manual).
tally = replay_pass(db, dry: dry, limit: (ENV["REPLAY_LIMIT"] || 100).to_i)
total = tally.values.sum
puts format("replay: done — %d match / %d mismatch / %d error / %d skipped of %d (parity %.1f%%)",
            tally[:match], tally[:mismatch], tally[:error], tally[:skipped], total,
            total.zero? ? 0.0 : (100.0 * tally[:match] / total))

# --- D7 part 3: whole-corpus parity report -----------------------------------
puts "corpus: status breakdown"
db[:battle_records].group_and_count(:replay_status, :mode)
                   .order(:replay_status, :mode).each do |r|
  puts format("  %-16s %-8s %d", r[:replay_status], r[:mode], r[:count])
end

# Per engine-build cohort: parity = match / (match + mismatch). A cohort whose
# parity collapses is a fork/version drift (or a cheat cluster) — part 3's core
# triage signal.
puts "corpus: parity by engine cohort"
db[:battle_records].where(replay_status: %w[match mismatch])
                   .group_and_count(:engine_fp, :replay_status).all
                   .group_by { |r| r[:engine_fp] }.each do |fp, rs|
  m  = rs.find { |r| r[:replay_status] == "match" }&.fetch(:count) || 0
  mm = rs.find { |r| r[:replay_status] == "mismatch" }&.fetch(:count) || 0
  puts format("  %-18s %4d match / %4d mismatch (%.1f%%)",
              (fp || "unknown")[0, 16], m, mm, m + mm > 0 ? 100.0 * m / (m + mm) : 0.0)
end
