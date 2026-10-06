require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/rate_limiter"

# The login limiter (per IP): a burst, a refill, and an address forgotten once its
# bucket has refilled - each address an attacker rotates through is not kept for good.
class RateLimiterTest < Minitest::Test
  def test_a_burst_then_the_refill
    l = PEMK::RateLimiter.new(max: 2, per: 10)
    assert l.allow?("a", now: 0.0)
    assert l.allow?("a", now: 0.0)
    refute l.allow?("a", now: 0.0)
    assert l.allow?("a", now: 5.0), "one token back after 5 s"
    assert l.allow?("b", now: 0.0), "another address has its own"
  end

  def test_a_refilled_bucket_is_forgotten
    l = PEMK::RateLimiter.new(max: 2, per: 10)
    l.allow?("a", now: 0.0)
    l.allow?("b", now: 6.0)
    assert_equal 0, l.prune(now: 9.9)
    assert_equal 1, l.prune(now: 10.0), "a has refilled"
    assert_equal 1, l.size
    assert_equal 1, l.prune(now: 16.0)
    assert_equal 0, l.size
    assert l.allow?("a", now: 16.0)
    assert l.allow?("a", now: 16.0), "a forgotten address starts full again"
  end
end
