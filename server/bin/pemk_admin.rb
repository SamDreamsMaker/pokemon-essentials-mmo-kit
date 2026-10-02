# frozen_string_literal: true

# The operator's moderation console. An account is named by its id or its email.
# A ban ends the account's sessions at once; the server refuses it at login and closes
# its live connection within seconds (PEMK::Server::BAN_SWEEP_SEC). Nothing is deleted:
# a lifted ban stays on record.
#
# Usage (WSL, from server/):
#   DATABASE_URL=... bundle exec ruby bin/pemk_admin.rb ban <account> [--days N | --hours N] [reason...]
#   DATABASE_URL=... bundle exec ruby bin/pemk_admin.rb unban <account>
#   DATABASE_URL=... bundle exec ruby bin/pemk_admin.rb bans              # the bans in force
#   DATABASE_URL=... bundle exec ruby bin/pemk_admin.rb show <account>    # the account, its bans, its flags
#   DATABASE_URL=... bundle exec ruby bin/pemk_admin.rb forget <account> --yes   # the right to be forgotten
# PEMK_OPERATOR names who acts in the record (default: the shell user).
#
# forget: on a player's request. Their email, name, password and sessions (with their
# addresses) go, and so does their own game state - the save, the bag, the party, the
# story flags, what they were owed. What stays, keyed by the account's number and naming
# nobody: the ledger and badges, their battles' records and proofs, the Pokemon they
# issued (another player may hold one), their trades, their flags and bans. A live
# connection is closed within seconds and purged again once its last work is done. The
# server's logs and the database's backups are the operator's to rotate.

require "sequel"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "pemk/bans"
require "pemk/sessions"
require "pemk/forget"

db       = Sequel.connect(ENV.fetch("DATABASE_URL"))
bans     = PEMK::Bans.new(db)
operator = ENV["PEMK_OPERATOR"] || ENV["USER"] || "operator"
cmd      = ARGV.shift

account = lambda do |key|
  abort "name an account (its id or its email)" if key.to_s.empty?
  row = key.match?(/\A\d+\z/) ? db[:accounts].where(id: key.to_i).first : db[:accounts].where(email: key).first
  abort "no account #{key}" unless row
  row
end

label = ->(a) { "account #{a[:id]} (#{a[:email] || 'forgotten'}#{a[:username] ? ", #{a[:username]}" : ''})" }
span  = ->(b) { b[:ends_at] ? "until #{b[:ends_at]}" : "until lifted" }

case cmd
when "ban"
  acct = account.(ARGV.shift)
  ends = nil
  if (i = ARGV.index("--days") || ARGV.index("--hours"))
    n = Integer(ARGV[i + 1], exception: false)
    abort "#{ARGV[i]} needs a whole number" unless n&.positive?
    ends = Time.now + (n * (ARGV[i] == "--days" ? 86_400 : 3600))
    ARGV.slice!(i, 2)
  end
  reason = ARGV.join(" ")
  db.transaction do
    bans.ban(acct[:id], reason: reason, by: operator, ends_at: ends)
    PEMK::Sessions.new(db).revoke_all(acct[:id])
  end
  puts "banned #{label.(acct)} #{ends ? "until #{ends}" : 'until lifted'}#{reason.empty? ? '' : " - #{reason}"}"

when "unban"
  acct = account.(ARGV.shift)
  n = bans.lift(acct[:id], by: operator)
  puts n.positive? ? "lifted #{n} ban(s) on #{label.(acct)}" : "#{label.(acct)} is not banned"

when "bans"
  now  = Time.now
  rows = db[:account_bans].where(lifted_at: nil)
                          .where(Sequel.|({ ends_at: nil }, Sequel.expr(:ends_at) > now))
                          .order(:created_at).all
  puts "#{rows.size} ban(s) in force:"
  rows.each do |b|
    a = db[:accounts].where(id: b[:account_id]).first
    puts "  #{label.(a)} since #{b[:created_at]} #{span.(b)} by #{b[:banned_by]}: #{b[:reason]}"
  end

when "forget"
  yes  = ARGV.delete("--yes")
  acct = account.(ARGV.shift)
  abort "forget is for good: name the account and add --yes" unless yes
  case PEMK::Forget.new(db).forget(acct[:id], by: operator)
  when :forgotten then puts "forgotten #{label.(acct)}: its personal data and its own state are gone; its records stay, naming nobody"
  when :already   then puts "account #{acct[:id]} was forgotten already (#{acct[:forgotten_at]}): purged again, nothing else"
  end

when "show"
  acct = account.(ARGV.shift)
  puts "#{label.(acct)} created #{acct[:created_at]}, last login #{acct[:last_login_at] || '-'}" \
       "#{acct[:forgotten_at] ? ", forgotten #{acct[:forgotten_at]}" : ''}"
  ban = bans.active(acct[:id])
  puts ban ? "BANNED #{span.(ban)}: #{ban[:reason]}" : "not banned"
  bans.history(acct[:id]).each do |b|
    lifted = b[:lifted_at] ? ", lifted #{b[:lifted_at]} by #{b[:lifted_by]}" : ""
    puts "  #{b[:created_at]} by #{b[:banned_by]} #{span.(b)}#{lifted}: #{b[:reason]}"
  end
  if db.table_exists?(:player_flags)
    flags = db[:player_flags].where(account_id: acct[:id]).all
    puts "suspicion flags: #{flags.empty? ? 'none' : flags.map { |f| "#{f[:kind]} x#{f[:count]}" }.join(', ')}"
  end
  if db.table_exists?(:monsters)
    q = db[:monsters].where(owner_account_id: acct[:id], status: "quarantined").count
    puts "quarantined Pokemon: #{q}"
  end

else
  puts File.read(__FILE__).lines.drop(2).take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 1
end
