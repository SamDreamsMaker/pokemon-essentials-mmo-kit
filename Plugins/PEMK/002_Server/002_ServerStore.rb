#===============================================================================
# PEMK :: ServerStore  (host side)
#-------------------------------------------------------------------------------
# The authoritative per-account state store, kept as one Marshal file per account
# on the host's disk (server_saves/<trainer_id>.rxdata). Same blob shape as the
# game's own save (a Hash{Symbol=>Object} from SaveData.compile_save_hash), so
# Player/PokemonBag/PokemonStorage objects round-trip with zero custom code.
#
# mkxp-z has no SQLite/DB, so files are the pragmatic store. Writes are atomic
# via a temp-file + rename. State here SURVIVES a server restart — that's the
# whole point of Phase 2b.
#===============================================================================
module PEMK
  module ServerStore
    DIR = "server_saves"

    def self.dir
      File.expand_path(DIR)
    end

    def self.ensure_dir
      # Dir.mkdir (core) instead of FileUtils.mkdir_p: mkxp-z's stdlib is minimal
      # and 'fileutils' may be unavailable (see Phase 0). server_saves is one
      # level deep, so a plain mkdir is enough.
      Dir.mkdir(dir) unless File.directory?(dir)
    rescue => e
      PEMK.log("store: mkdir failed: #{e.class}: #{e.message}")
    end

    def self.path(account_id)
      File.join(dir, "#{account_id.to_s.gsub(/[^A-Za-z0-9_-]/, '_')}.rxdata")
    end

    # A fresh, unused 31-bit trainer id (the account identity + store key).
    def self.new_account_id
      loop do
        id = rand(2**31 - 1) + 1
        return id unless File.file?(path(id))
      end
    end

    # Returns the stored state Hash for an account, or nil if this host has none.
    def self.load_state(account_id)
      p = path(account_id)
      return nil unless File.file?(p)
      File.open(p, "rb") { |f| Marshal.load(f) }
    rescue => e
      PEMK.log("store: load failed for #{account_id}: #{e.class}: #{e.message}")
      nil
    end

    # Persists an account's state Hash (atomic-ish). Returns true on success.
    def self.save_state(account_id, hash)
      return false unless hash.is_a?(Hash)
      ensure_dir
      final = path(account_id)
      tmp = final + ".tmp"
      File.open(tmp, "wb") { |f| Marshal.dump(hash, f) }
      File.delete(final) if File.file?(final)   # Windows rename won't overwrite
      File.rename(tmp, final)
      true
    rescue => e
      PEMK.log("store: save failed for #{account_id}: #{e.class}: #{e.message}")
      false
    end
  end
end
