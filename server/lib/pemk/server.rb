# frozen_string_literal: true

require "time"

module PEMK
  # Milestone 1c skeleton: boots config + Postgres + the reactor and logs decoded
  # envelopes. Auth-gate, per-player mailbox/workers, zone presence and the save
  # store land in the next increments; the message handler here is intentionally
  # tiny (a :ping/:pong round-trip proves the wire end to end).
  class Server
    def self.log(msg)
      $stdout.puts("#{Time.now.utc.iso8601} #{msg}")
      $stdout.flush
    end

    def initialize(config: Config.new, logger: nil)
      @config  = config
      @log     = logger || self.class.method(:log)
      @db      = DB.connect(@config.database_url)
      @reactor = Reactor.new(
        host: @config.bind, port: @config.port,
        on_frame: method(:on_frame), on_close: method(:on_close), logger: @log
      )
    end

    def run
      @db.test_connection
      @log.call("server: db ok (#{@db.opts[:database]})")
      @log.call("server: economy caps #{@config.economy_caps}, badges<#{@config.badges_max}")
      install_signal_handlers
      @reactor.run
      @log.call("server: stopped")
    end

    private

    def on_frame(conn, payload)
      dec = Wire.decode_envelope(payload, false) # host path: reject legacy whole-Marshal
      unless dec
        @log.call("server: bad/legacy frame from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      env = dec[:env]
      @log.call("server: #{env[:type].inspect} from #{conn.addr} body=#{dec[:body]&.bytesize || 0}B")

      case env[:type]
      when :ping
        @reactor.send_frame(conn, Wire.encode_split({ type: :pong, t: env[:t] }))
      end
    end

    def on_close(_conn); end

    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { @reactor.stop } }
    end
  end
end
