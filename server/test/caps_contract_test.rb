require "minitest/autorun"

# Every cap the server may require at login (update_required) is one the shipped client
# says it has: a cap the server asks for and the client never says would lock every player
# out of the server that enforces it.
class CapsContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_the_client_says_every_cap_the_server_requires
    auth = File.read(File.join(ROOT, "Plugins", "PEMK", "004_Persist", "001_Auth.rb"))
    client = auth[/CAPS = %w\[([^\]]*)\]/m, 1].split
    server = File.read(File.join(ROOT, "server", "lib", "pemk", "server.rb"))
    required = server[/def money_update_required\?.*?\n    end\n/m].scan(/caps\.include\?\("(\w+)"\)/).flatten
    assert_equal %w[money_claims trainer_proof badge_hold badge_alone], required
    assert_empty required - client, "the server requires caps the client never says"
  end
end
