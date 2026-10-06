# frozen_string_literal: true

module PEMK
  # Token-bucket rate limiter, reactor-thread only (no lock). Used to throttle
  # login/register attempts per client IP BEFORE any bcrypt work is queued, so a
  # flooding IP can't tie up the KDF/worker pool. Buckets are created lazily and
  # pruned once they have refilled: a full bucket is the same as none.
  class RateLimiter
    def initialize(max:, per:)
      @max     = max.to_f
      @per     = per.to_f
      @rate    = @max / per          # tokens refilled per second
      @buckets = {}                  # key => [tokens, last_monotonic]
    end

    def allow?(key, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      tokens, last = @buckets[key] || [@max, now]
      tokens = [@max, tokens + ((now - last) * @rate)].min
      if tokens >= 1.0
        @buckets[key] = [tokens - 1.0, now]
        true
      else
        @buckets[key] = [tokens, now]
        false
      end
    end

    # Drop the buckets untouched for a whole refill: each address an attacker rotates
    # through would otherwise be kept for good. -> how many were dropped
    def prune(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      before = @buckets.size
      @buckets.delete_if { |_, (_, last)| now - last >= @per }
      before - @buckets.size
    end

    def size
      @buckets.size
    end
  end
end
