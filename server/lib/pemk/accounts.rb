# frozen_string_literal: true

module PEMK
  # Account repository: registration + authentication with per-account lockout.
  # A thin data-access layer over the :accounts table (Sequel), no ORM models.
  class Accounts
    USERNAME_RE   = /\A[A-Za-z0-9_]{3,20}\z/
    MIN_PASSWORD  = 8
    MAX_FAILS     = 5           # lock after this many consecutive bad passwords
    LOCK_SECONDS  = 300         # 5 minutes

    def initialize(db)
      @db = db
    end

    # Returns the new account id, or nil if the username/email is already taken.
    # Raises ArgumentError on malformed input (caller maps to a client error).
    def create(username:, password:, email: nil, now: Time.now)
      username = username.to_s
      raise ArgumentError, "invalid_username" unless USERNAME_RE.match?(username)
      raise ArgumentError, "weak_password"    unless password.to_s.length >= MIN_PASSWORD

      @db[:accounts].insert(
        username:      username,
        email:         (email.to_s.empty? ? nil : email.to_s),
        password_hash: Password.hash(password),
        status:        "active",
        created_at:    now
      )
    rescue Sequel::UniqueConstraintViolation
      nil
    end

    # -> [account_row, nil] on success, or [nil, reason] where reason is one of
    # :not_found, :locked, :bad_password. Consumes a failed attempt + locks the
    # account after MAX_FAILS; resets the counter on success.
    def authenticate(username, password, now: Time.now)
      acct = @db[:accounts].where(username: username.to_s).first
      return [nil, :not_found] unless acct
      return [nil, :locked] if acct[:locked_until] && acct[:locked_until] > now

      if Password.verify(password, acct[:password_hash])
        @db[:accounts].where(id: acct[:id])
                      .update(failed_count: 0, locked_until: nil, last_login_at: now)
        [acct, nil]
      else
        fails  = acct[:failed_count].to_i + 1
        locked = fails >= MAX_FAILS ? now + LOCK_SECONDS : nil
        @db[:accounts].where(id: acct[:id]).update(failed_count: fails, locked_until: locked)
        [nil, :bad_password]
      end
    end

    def find(account_id)
      @db[:accounts].where(id: account_id).first
    end
  end
end
