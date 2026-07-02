# frozen_string_literal: true

require "securerandom"
require "digest"

module PEMK
  # Session repository: opaque 256-bit tokens. The DB stores only sha256(token);
  # the raw token is returned once (to the client) and never persisted, so a DB
  # leak can't be replayed. Sliding idle expiry + absolute expiry + revocation.
  class Sessions
    IDLE_TTL = 7  * 24 * 3600   # drop a session unused for 7 days
    ABS_TTL  = 30 * 24 * 3600   # hard cap 30 days regardless of activity

    def initialize(db)
      @db = db
    end

    # Issue a fresh session; returns the raw token (hex, 256-bit).
    def issue(account_id, remote_addr: nil, now: Time.now)
      token = SecureRandom.hex(32)
      @db[:sessions].insert(
        token_sha256: Sequel.blob(digest(token)),
        account_id:   account_id,
        issued_at:    now,
        last_seen_at: now,
        expires_at:   now + ABS_TTL,
        revoked:      false,
        remote_addr:  remote_addr
      )
      token
    end

    # Resolve a token to an account_id (touching last_seen), or nil if unknown,
    # revoked, absolutely expired, or idle-expired.
    def resolve(token, now: Time.now)
      return nil if token.to_s.empty?

      row = @db[:sessions].where(token_sha256: Sequel.blob(digest(token))).first
      return nil unless row
      return nil if row[:revoked]
      return nil if row[:expires_at] <= now
      return nil if row[:last_seen_at] + IDLE_TTL <= now

      @db[:sessions].where(token_sha256: row[:token_sha256]).update(last_seen_at: now)
      row[:account_id]
    end

    def revoke(token)
      @db[:sessions].where(token_sha256: Sequel.blob(digest(token))).update(revoked: true)
    end

    def digest(token)
      Digest::SHA256.digest(token.to_s)
    end
  end
end
