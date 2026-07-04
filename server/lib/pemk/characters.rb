# frozen_string_literal: true

module PEMK
  # Character (save) repository. The save is stored as an OPAQUE bytea blob and is
  # NEVER Marshal.load'd on the server — the owning client rehydrates its own
  # bytes. M1 = one character per account (unique account_id); relational
  # projection of economy/inventory/party for anti-cheat arrives in M2/M3.
  class Characters
    def initialize(db)
      @db = db
    end

    # Save blob bytes (String) for an account, or nil if it has none yet.
    def load_blob(account_id)
      blob = @db[:characters].where(account_id: account_id).get(:save_blob)
      blob&.to_s
    end

    # The last SERVER-VALIDATED position [map,x,y] for an account, or nil if none yet
    # (M4 Layer B: seeds the position audit's last_pos at login).
    def load_position(account_id)
      r = @db[:characters].where(account_id: account_id).select(:last_map, :last_x, :last_y).first
      return nil unless r && r[:last_map] && r[:last_x] && r[:last_y]

      [r[:last_map], r[:last_x], r[:last_y]]
    end

    # Upsert the account's save (last-write-wins). Postgres ON CONFLICT on the
    # unique account_id. +position+ (a validated [map,x,y]) is persisted alongside;
    # a nil/invalid position is OMITTED from the write so it never overwrites a
    # previously-stored position with NULL.
    def store(account_id, blob:, trainer_id: nil, save_version: nil, wire_version: nil, position: nil, now: Time.now)
      raise ArgumentError, "empty blob" unless blob.is_a?(String) && !blob.empty?

      row = {
        account_id:   account_id,
        save_blob:    Sequel.blob(blob),
        trainer_id:   trainer_id,
        save_version: save_version,
        wire_version: wire_version,
        updated_at:   now
      }
      if position.is_a?(Array) && position.size == 3 && position.all? { |n| n.is_a?(Integer) }
        row[:last_map], row[:last_x], row[:last_y] = position
      end
      @db[:characters]
        .insert_conflict(target: :account_id, update: row.reject { |k, _| k == :account_id })
        .insert(row)
    end
  end
end
