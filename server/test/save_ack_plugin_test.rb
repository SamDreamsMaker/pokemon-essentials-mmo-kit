require "minitest/autorun"
require "rbconfig"
require "tmpdir"

# Durability: a save pushed to the server counts once the server says it was written.
# A save it could not write (a database error, a full queue), or never answers, goes
# out again, later each time; one refused as too large does not; an older server that
# answers nothing is trusted as before.
class SaveAckPluginTest < Minitest::Test
  SYNC     = File.expand_path("../../Plugins/PEMK/006_Sync/001_Sync.rb", __dir__)
  DISPATCH = File.expand_path("../../Plugins/PEMK/003_Game/004_Dispatch.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $later = 0; $notes = []; $now = 1000.0
    def _INTL(s, *_a); s; end
    module Graphics; def self.frame_count; 0; end; end
    class FakeClient
      attr_accessor :up
      def initialize; @up = true; end
      def connected?; @up; end
      def send_message(m, _body = nil); $sent << m; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Checkpoint; def self.request(_r); end; def self.push_later; $later += 1; end; end
      module NetStatus
        def self.notify(key, msg); $notes << [key, msg]; end
        def self.reset_key(_k); end
      end
    end
    $game_temp = Struct.new(:in_battle).new(false)
    load ARGV[0]
    load ARGV[1]
    PEMK::Sync.define_singleton_method(:mono) { $now }

    file = File.join(ARGV[2], "Game.rxdata")
    sync = PEMK::Sync
    push = ->(bytes, force: true) { File.binwrite(file, bytes); sync.push_blob(file, force: force) }
    last = -> { $sent.select { |m| m[:type] == :save }.last[:seq] }
    answer = ->(type, seq, reason = nil) { PEMK::Dispatch.handle({ type: type, seq: seq, reason: reason }) }
    out = {}

    sync.adopt_save_ack(true)
    push.("one")
    answer.(:save_ok, last.())
    out[:written] = [$later, $notes.size]

    push.("two")                               # the database refuses it
    answer.(:save_err, last.(), "store_failed")
    early = sync.push_blob(file, force: false) # not before its time...
    $now += 5
    again = sync.push_blob(file, force: false) # ... then the same bytes again
    out[:refused] = [$later, early, again, last.(), $notes.last[1]]
    answer.(:save_ok, last.())
    out[:back] = $notes.last[1]

    push.("three")                             # never answered
    $now += 31
    sync.tick
    $now += 10
    out[:silent] = [$later, sync.push_blob(file, force: false), last.()]

    push.("four")                              # an answer to an older save is overtaken
    notes = $notes.size
    answer.(:save_err, last.() - 1, "store_failed")
    out[:stale] = [$notes.size - notes, sync.push_blob(file, force: true)]

    push.("five")                              # too large: sending it again cannot help
    later = $later
    answer.(:save_err, last.(), "too_large")
    $now += 60
    sync.tick
    out[:too_large] = [$later - later, $notes.last[1]]

    push.("six")                               # the connection goes before the answer:
    PEMK.client.up = false                     # the reconnect sends the save anyway
    later = $later
    $now += 60
    sync.tick
    out[:offline] = [$later - later, $sent.count { |m| m[:type] == :save }]
    count = $sent.count { |m| m[:type] == :save }
    PEMK.client.up = true
    $now += 60
    sync.tick
    out[:offline] << ($sent.count { |m| m[:type] == :save } - count)

    sync.reset                                 # an older server answers nothing
    PEMK.client.up = true
    push.("seven")
    later = $later
    $now += 60
    sync.tick
    out[:old_server] = $later - later
    print out.inspect
  RUBY

  def test_a_save_counts_once_the_server_wrote_it
    out = Dir.mktmpdir do |dir|
      IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, SYNC, DISPATCH, dir], err: %i[child out], &:read)
    end
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal [0, 0], got[:written]
    assert_equal [1, :throttled, :pushed, 3, "Your progress could not be saved to the server. Trying again..."],
                 got[:refused]
    assert_equal "Your progress is saving online again.", got[:back]
    assert_equal [2, :pushed, 5], got[:silent], "no answer in 30 s: sent again after 5 s"
    assert_equal [0, :unchanged], got[:stale]
    assert_equal [0, "This save is too large for the server: your progress is only kept on this computer."],
                 got[:too_large]
    assert_equal [0, 8, 0], got[:offline], "no retry of its own: it waits for the reconnect"
    assert_equal 0, got[:old_server]
  end

  # Trainer proof P4: a pushed save names the prize claims its bytes carry (a claim held
  # for its proof survives a fresh login only if the save that loads has it) - known once
  # this session wrote the file, and still the file's after a reconnect.
  CLAIMS_RUNNER = <<~'RUBY'
    $sent = []; $claims = []
    def _INTL(s, *_a); s; end
    module Graphics; def self.frame_count; 0; end; end
    class FakeClient; def connected?; true; end; def send_message(m, _b = nil); $sent << m; end; end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module PrizeClaim; def self.claims; $claims; end; end
    end
    $game_temp = Struct.new(:in_battle).new(false)
    load ARGV[0]
    file = File.join(ARGV[1], "Game.rxdata")
    sync = PEMK::Sync
    push = ->(bytes) { File.binwrite(file, bytes); sync.push_blob(file, force: true); $sent.last }
    out = {}
    out[:unknown] = push.("from an older session").key?(:claims)
    $claims = [[11, [], 400, false, false, 31, nil, 5], [12, :payday, 60, false, false, 31, {}]]
    sync.mark_blob_watermark   # this session writes the file
    $claims = []               # ... then the claims are answered
    out[:named] = push.("written")[:claims]
    sync.reset
    out[:after_reconnect] = push.("written, again")[:claims]
    $claims = (1..70).map { |n| [n, [], 1, false, false, 31, nil] }
    sync.mark_blob_watermark
    out[:newest] = push.("many")[:claims]
    print out.inspect
  RUBY

  def test_a_save_names_the_claims_it_carries
    out = Dir.mktmpdir do |dir|
      IO.popen([RbConfig.ruby, "-W0", "-e", CLAIMS_RUNNER, SYNC, dir], err: %i[child out], &:read)
    end
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal false, got[:unknown], "a file from before this session: nothing named"
    assert_equal [11, 12], got[:named], "the claims the file was written with, not the list now"
    assert_equal [11, 12], got[:after_reconnect]
    assert_equal (7..70).to_a, got[:newest], "the 64 newest: the battles just won"
  end
end
