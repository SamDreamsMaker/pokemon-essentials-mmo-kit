# frozen_string_literal: true

module PEMK
  # Token-bucket rate limiter, reactor-thread only (no lock). Used to throttle
  # login/register attempts per client IP BEFORE any bcrypt work is queued, so a
  # flooding IP can't tie up the KDF/worker pool. Buckets are created lazily; a
  # periodic reaper for idle buckets is a later refinement (bounded by #IPs).
  class RateLimiter
    def initialize(max:, per:)
      @max     = max.to_f
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

    def size
      @buckets.size
    end
  end
end
