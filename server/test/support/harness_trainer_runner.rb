# frozen_string_literal: true

# Subprocess body for harness_trainer_test.rb: boot the headless engine, replay a real
# trainer battle record as recorded and with one thing changed each time, and print one
# JSON line of verdicts LAST (boot noise may precede it).

server_root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(server_root, "lib"))
$LOAD_PATH.unshift(File.expand_path("../protocol", server_root))

require "json"
require "pemk_wire"
require "pemk_prng"
require_relative "../../harness/harness"

game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", server_root)
PEMK::Harness.boot!(game_root: game_root)

fresh = -> { PEMK::Wire.decode_primitive(File.binread(ARGV[0])) }
TAMPERS = {
  "as recorded"     => ->(_r) {},
  # the trainer's AI healed with a Full Restore in round 2; a client says it attacked
  "ai choice"       => ->(r) { r[:rounds][2][:c][1] = ["UseMove", 1, "HEADSMASH", 0] },
  # the AI sent in Onix; a client says the trainer sent in nothing else
  "ai switch"       => ->(r) { r[:switches] = [[1, 0]] },
  # a weaker foe than the game's
  "foe level"       => ->(r) { r[:init][:foe][0][:level] = 5 },
  "foe moves"       => ->(r) { r[:init][:foe][1][:moves] = ["TACKLE"] },
  # the trainer's bag emptied
  "bag"             => ->(r) { r[:settings][:items] = [[]] },
  # a trainer the game's data does not have
  "trainer"         => ->(r) { r[:trainers] = [["LEADER_Brock", "Brock", 7]] },
  "no trainer name" => ->(r) { r[:trainers] = [nil] },
  # the level-20 Wartortle from another trainer: with no badge it would have disobeyed
  # (the game rolls for it), with one it obeys up to level 20 - as it did
  "traded, no badge"  => ->(r) { r[:init][:player].each { |f| f[:foreign] = true }; r[:init][:badges] = 0 },
  "traded, one badge" => ->(r) { r[:init][:player].each { |f| f[:foreign] = true }; r[:init][:badges] = 1 }
}.freeze

verdicts = TAMPERS.map do |name, tamper|
  rec = fresh.call
  tamper.call(rec)
  res = PEMK::Harness.replay(rec)
  { tamper: name, verdict: res[:verdict].to_s, detail: res[:detail], prize: res[:prize] }
end

puts JSON.generate(verdicts)
