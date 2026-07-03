# frozen_string_literal: true

require "bcrypt"
require "digest"

module PEMK
  # Password hashing = bcrypt(cost 12) over a SHA-256 pre-hash of the password.
  # The pre-hash (a) removes bcrypt's 72-byte truncation (long passphrases stay
  # fully significant) and (b) avoids embedded NUL issues. argon2id is a possible
  # opt-in later; bcrypt is the shipped default (it "just builds").
  module Password
    COST = 12

    module_function

    def hash(plain)
      BCrypt::Password.create(prehash(plain), cost: COST).to_s
    end

    def verify(plain, digest)
      return false if digest.nil? || digest.empty?

      BCrypt::Password.new(digest) == prehash(plain)
    rescue BCrypt::Errors::InvalidHash
      false
    end

    def prehash(plain)
      Digest::SHA256.hexdigest(plain.to_s)
    end
  end
end
