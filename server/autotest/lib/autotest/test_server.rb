# frozen_string_literal: true

require "timeout"

module Autotest
  # A PEMK server in this process, on the test port and the pemk_autotest database,
  # booted with one scenario's flags. Bound to 0.0.0.0 so the Windows game reaches
  # it through WSL's localhost forwarding, like the dev server.
  class TestServer
    attr_reader :port, :lines

    def initialize(port:, flags:, log_path:)
      @port     = port
      @flags    = flags
      @log_path = log_path
      @lines    = []
      @mutex    = Mutex.new
    end

    def start
      @file = File.open(@log_path, "a")
      boot
      self
    end

    def stop
      @server&.stop
      @file&.close
    end

    # A deploy, as the connected windows see it: the server stops, and a new one
    # comes up on the same port, database and flags.
    def restart
      @server&.stop
      log("autotest: the server restarts")
      boot
      self
    end

    def grep(pattern)
      @mutex.synchronize { @lines.grep(pattern) }
    end

    # Badge authority B2: the badges the server shows this account - owned and pending.
    def badges_shown(account_id)
      @server.send(:badge_shown, account_id)
    end

    # Money authority: money a scenario hands out itself is a source the server knows, so
    # the shadow balance explains it (the harness's grant; nothing a client can send).
    # Enforced (M3), the grant is the ledger's own: the balance becomes +total+ on the
    # account's mailbox, before the client's frame shows it.
    def explain_money(account_id, amount, total: nil)
      db = @server.instance_variable_get(:@db)
      before = db[:economy_balances].where(account_id: account_id, field: "money").get(:balance)
      grant_money(account_id, total) if total && @server.instance_variable_get(:@money_enforce)
      shadow = @server.instance_variable_get(:@money_shadow)
      shadow.claim(account_id, amount, before: before) if shadow && amount.positive?
    end

    def grant_money(account_id, total)
      done = Queue.new
      @server.instance_variable_get(:@mailbox).submit(account_id) do
        ledger = @server.instance_variable_get(:@ledger)
        delta = total - ledger.current(account_id, :money)
        ledger.adjust(account_id, :money, delta, reason: "autotest") unless delta.zero?
      ensure
        done << true
      end
      Timeout.timeout(10) { done.pop }
    end

    # Sends a frame to +account_id+'s window as the server would, for a test that needs
    # the game to handle one (a correction, a notice). -> whether the account was online.
    def tell(account_id, **env)
      done = Queue.new
      @server.instance_variable_get(:@reactor).post do
        conn = @server.instance_variable_get(:@online)[account_id]
        @server.send(:reply, conn, **env) if conn
        done << !conn.nil?
      end
      Timeout.timeout(10) { done.pop }
    end

    # The last position the server holds for +account_id+'s connection ([map, x, y] | nil).
    def last_pos(account_id)
      done = Queue.new
      @server.instance_variable_get(:@reactor).post do
        conn = @server.instance_variable_get(:@online)[account_id]
        done << (conn && conn.data[:last_pos])
      end
      Timeout.timeout(10) { done.pop }
    end

    # The next +times+ saves of +account_id+ are not written, as on a database error.
    def fail_saves(account_id, times = 1)
      left = times
      chars = @server.instance_variable_get(:@characters)
      chars.singleton_class.prepend(Module.new do
        define_method(:store) do |aid, **kw|
          if aid == account_id && left.positive?
            left -= 1
            raise "autotest: the database refused the save"
          end
          super(aid, **kw)
        end
      end)
    end

    # Keeps +account_id+'s mailbox busy for +seconds+: what the account asks meanwhile is
    # answered late, as by a slow server.
    def hold_account(account_id, seconds)
      @server.instance_variable_get(:@mailbox).submit(account_id) { sleep seconds }
    end

    private

    def boot
      # debug mode locked, the autopilot obeyed: every scenario plays as a locked client
      env = ENV.to_h.merge("PEMK_BIND" => "0.0.0.0", "PEMK_PORT" => @port.to_s, "PEMK_CLIENT_DEBUG" => "autopilot")
      @flags.each { |k, v| env[k.to_s] = v.to_s }
      @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: method(:log))
      @server.start
    end

    def log(message)
      line = "#{Time.now.strftime('%H:%M:%S.%L')} #{message}"
      @mutex.synchronize do
        @lines << line
        @file.puts(line)
        @file.flush
      end
    end
  end
end
