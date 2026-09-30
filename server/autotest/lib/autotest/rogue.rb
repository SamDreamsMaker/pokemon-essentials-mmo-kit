# frozen_string_literal: true

require "socket"

module Autotest
  # A client that speaks the wire protocol by hand: an attacker, or a player with a
  # modified game. It logs in like the game does, then sends whatever frame a test
  # needs; the frames it receives are kept for the test to read.
  class Rogue
    PASSWORD = "rogue-password-1"

    attr_reader :account_id, :email

    def initialize(port, email:, caps: nil)
      @port  = port
      @email = email
      @caps  = caps   # what a modified game says it can do (nil: nothing, as an old one)
      @inbox = []
      @mutex = Mutex.new
    end

    def connect
      @sock   = TCPSocket.new("127.0.0.1", @port)
      @reader = Thread.new { read_loop }
      send_env(type: :register, email: @email, password: PASSWORD)
      wait_for(:register_ok, :register_err)
      login = { type: :login, email: @email, password: PASSWORD }
      login[:caps] = @caps if @caps
      send_env(login)
      reply = wait_for(:login_ok, :login_err)
      raise Failure, "rogue: login refused (#{reply[:env][:reason]})" unless reply[:env][:type] == :login_ok

      @account_id = reply[:env][:account_id]
      self
    end

    def send_env(env, body = nil)
      @sock.write(PEMK::Wire.encode_split(env, body))
    end

    # Takes the first frame of one of +types+, received already or within +seconds+.
    def wait_for(*types, seconds: 10)
      deadline = Autotest.mono + seconds
      loop do
        found = @mutex.synchronize do
          i = @inbox.index { |f| types.include?(f[:env][:type]) }
          i && @inbox.delete_at(i)
        end
        return found if found
        raise Failure, "rogue: no #{types.join('/')} after #{seconds}s" if Autotest.mono > deadline

        sleep 0.05
      end
    end

    def close
      @sock&.close
      @reader&.join(1)
    rescue IOError, SystemCallError
      nil
    end

    private

    def read_loop
      loop do
        header = @sock.read(4) or break
        payload = @sock.read(header.unpack1("N")) or break
        frame = PEMK::Wire.decode_envelope(payload, false)
        @mutex.synchronize { @inbox << frame } if frame
      end
    rescue IOError, SystemCallError
      nil
    end
  end
end
