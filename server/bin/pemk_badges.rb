# frozen_string_literal: true

# The operator's badge console (badge authority B2, docs/BADGE-AUTHORITY-DESIGN.md). An
# account is named by its id or its email.
#
# Usage (WSL, from server/):
#   DATABASE_URL=... bundle exec ruby bin/pemk_badges.rb list <account>             # owned and why, pending, shown
#   DATABASE_URL=... bundle exec ruby bin/pemk_badges.rb grant <account> <badge> [note...]
#   DATABASE_URL=... bundle exec ruby bin/pemk_badges.rb unowned [<account>]         # wins no replay proved
# PEMK_OPERATOR names who acts in the record (default: the shell user). A grant reaches the
# player at their next login or badge frame. `unowned` lists the wins over a badge's trainer
# that own nothing - claimed with no seed, not replayable, refuted, never recorded - for the
# operator to look at: an honest player's battle begun offline is one of them.

require "sequel"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "pemk/config"
require "pemk/ledger"
require "pemk/world_data"
require "pemk/badge_audit"

db       = Sequel.connect(ENV.fetch("DATABASE_URL"))
config   = PEMK::Config.new
ledger   = PEMK::Ledger.new(db, config.economy_caps)
world    = PEMK::WorldData.new(config.world_path)
audit    = PEMK::BadgeAudit.new(db, world)
operator = ENV["PEMK_OPERATOR"] || ENV["USER"] || "operator"
cmd      = ARGV.shift

account = lambda do |key|
  abort "name an account (its id or its email)" if key.to_s.empty?
  row = key.match?(/\A\d+\z/) ? db[:accounts].where(id: key.to_i).first : db[:accounts].where(email: key).first
  abort "no account #{key}" unless row
  row
end

label = ->(a) { "account #{a[:id]} (#{a[:email]})" }
bits  = ->(mask) { audit.bits_of(mask).then { |l| l.empty? ? "none" : l.join(", ") } }

case cmd
when "list"
  acct = account.(ARGV.shift)
  owned = ledger.current(acct[:id], :badges).to_i
  pending = audit.pending_bits(acct[:id])
  puts "#{label.(acct)}: owns #{bits.(owned)}; pending #{bits.(pending & ~owned)}; shown #{bits.(owned | pending)}"
  db[:badge_grants].where(account_id: acct[:id]).order(:badge).each do |g|
    puts "  badge #{g[:badge]}: #{g[:evidence]} #{g[:source]} (#{g[:granted_at]})"
  end

when "grant"
  acct = account.(ARGV.shift)
  badge = Integer(ARGV.shift.to_s, exception: false)
  abort "name a badge: 0 to #{config.badges_max - 1}" unless badge&.between?(0, config.badges_max - 1)
  note = ARGV.join(" ")
  source = [operator, note].reject(&:empty?).join(": ")[0, 160]
  after = ledger.grant_bits(acct[:id], 1 << badge, reason: "badge:operator:#{operator}"[0, 64],
                                                  grants: [{ badge: badge, evidence: "operator", source: source }])
  puts "granted badge #{badge} to #{label.(acct)} - it owns #{bits.(after)}"

when "unowned"
  key = ARGV.shift
  # a trainer's prize claims, not voided, not proven (NULL included: no proof)
  unproven = db[:money_claims].where(kind: PEMK::BadgeAudit::KINDS, voided_at: nil)
                              .where(Sequel.|({ proof: nil }, Sequel.~(proof: "proven")))
  ids = key ? [account.(key)[:id]] : unproven.distinct.select_map(:account_id)
  found = 0
  ids.sort.each do |id|
    owned = ledger.current(id, :badges).to_i
    unproven.where(account_id: id).order(:created_at).each do |c|
      wins = audit.wins_in(c).reject { |b| owned[b] == 1 }
      next if wins.empty?

      why = c[:proof] || (c[:trainer_battle_id] ? "waiting for its replay" : "claimed with no seed")
      next if why == "waiting for its replay"

      found += 1
      puts "account #{id} claim #{c[:nonce]} (#{c[:created_at]}): badge #{wins.join(', ')} - #{why} " \
           "(bin/pemk_badges.rb grant #{id} #{wins.first} if it was earned)"
    end
  end
  puts "#{found} win(s) owning no badge"

else
  abort "usage: pemk_badges.rb list <account> | grant <account> <badge> [note...] | unowned [<account>]"
end
