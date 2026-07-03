# frozen_string_literal: true

require "thread"

module PEMK
  # Fixed pool of worker threads that run blocking jobs (Postgres, bcrypt) off the
  # reactor thread. A job hands its result back with reactor.post { ... } so the
  # reply is applied on the reactor thread. FIFO; jobs for a single player are kept
  # in order by a per-player mailbox (a later increment) — the pool itself is
  # order-agnostic.
  class WorkerPool
    def initialize(size:, logger: nil)
      @size    = size
      @jobs    = Queue.new
      @log     = logger || ->(_m) {}
      @threads = []
    end

    def start
      @threads = Array.new(@size) { Thread.new { worker_loop } }
    end

    def submit(&job)
      @jobs << job
    end

    def shutdown
      @size.times { @jobs << :stop }
      @threads.each { |t| t.join(5) }
      @threads = []
    end

    private

    def worker_loop
      loop do
        job = @jobs.pop
        break if job == :stop

        begin
          job.call
        rescue StandardError => e
          @log.call("worker: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
