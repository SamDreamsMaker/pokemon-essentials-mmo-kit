#===============================================================================
# PEMK :: Monsters  (client side — M3.1, server-issued monster UIDs)
#-------------------------------------------------------------------------------
# Every Pokémon the player owns gets a server-minted identity (@pemk_uid). No
# acquisition hooks: a SELF-HEALING SWEEP over party + boxes at flush time finds
# instances without a uid and batch-requests one — 100% coverage by construction
# (catches, eggs, gifts, debug adds, legacy saves) — the same argument that won
# for the bag. Three tiny flag-only aliases just shorten the latency.
#
# Idempotency (the make-or-break): each instance gets a PERSISTED random nonce
# (@pemk_nonce, written BEFORE the request so it Marshals into the next save).
# The server dedups on UNIQUE(issuer, nonce), so any replay — lost grant,
# reconnect, crash-after-save — re-receives the SAME uid. Grants are matched by
# nonce, never by party index (the party can reorder while a request is in flight).
#
# The party (only) is also projected as [{uid, species, level}] so the server can
# flag a uid appearing where it should not (copied-save dupes). M3.1 is a
# WRITE-ONLY shadow: the save blob stays authoritative for Pokémon data.
#
# HONEST: this makes instances traceable and (M3.2) trade-gated, NOT unforgeable.
#===============================================================================

# --- identity ivars + clone guard ---------------------------------------------
# Reopen (not edit) the core class. Marshal persists ivars automatically; old
# saves simply read nil (= needs a uid). Pokemon#clone copies ALL ivars via super
# and the debug menu persists clones — a copy is a NEW identity, so both ivars
# are cleared on the copy (else one debug clone = two mons sharing a uid forever).
class Pokemon
  attr_accessor :pemk_uid     # server-issued identity (nil until granted)
  attr_accessor :pemk_nonce   # persisted mint-idempotency token

  unless method_defined?(:pemk_orig_clone)
    alias_method :pemk_orig_clone, :clone
    def clone
      ret = pemk_orig_clone
      ret.pemk_uid   = nil
      ret.pemk_nonce = nil
      ret
    end
  end
end

module PEMK
  module Monsters
    UID_REQ_MAX = 64   # mint entries per frame (mirrors the server cap)

    @inflight = {}     # nonce => true (session-only politeness; resends are server-idempotent)

    module_function

    def reset
      @inflight = {}
    end

    # Yield every Pokémon in the player's possession: party, then box slots.
    def each_owned
      ($player.party.each { |p| yield p if p } if $player&.party)
      storage = $PokemonStorage
      if storage&.boxes
        storage.boxes.each do |box|
          next unless box
          box.each { |p| yield p if p }
        end
      end
    rescue => e
      PEMK.log("mon: each_owned error: #{e.class}: #{e.message}")
    end

    # Collect up to +max+ mint requests for uid-less mons, assigning each a
    # persisted nonce FIRST (so it rides the next save). -> [entries, more_pending]
    def pending_batch(max = UID_REQ_MAX)
      entries = []
      more    = false
      each_owned do |pkmn|
        next unless pkmn.pemk_uid.nil?
        if entries.length >= max
          more = true
          break
        end
        pkmn.pemk_nonce ||= new_nonce
        next if @inflight[pkmn.pemk_nonce]
        entries << {
          :tmp     => pkmn.pemk_nonce,
          :species => pkmn.species,
          :level   => pkmn.level,
          :pid     => pkmn.personalID,
          :egg     => (pkmn.egg? ? true : false)
        }
        @inflight[pkmn.pemk_nonce] = true
      end
      [entries, more]
    rescue => e
      PEMK.log("mon: pending_batch error: #{e.class}: #{e.message}")
      [[], false]
    end

    def new_nonce
      (SecureRandom.random_number(2**62) rescue rand(2**62)) + 1
    end

    # Match grants to instances by NONCE over party+boxes (never by index). Plain
    # ivar writes — no observers fire, so no silent/applying guard is needed.
    def on_grant(msg)
      grants = msg && msg[:grants]
      return unless grants.is_a?(Array) && !grants.empty?

      by_nonce = {}
      grants.each do |g|
        next unless g.is_a?(Hash) && g[:tmp].is_a?(Integer) && g[:uid].is_a?(Integer)
        by_nonce[g[:tmp]] = g[:uid]
      end
      applied = 0
      each_owned do |pkmn|
        next unless pkmn.pemk_uid.nil? && pkmn.pemk_nonce && by_nonce.key?(pkmn.pemk_nonce)
        pkmn.pemk_uid = by_nonce[pkmn.pemk_nonce]
        applied += 1
      end
      # Consume EVERY granted nonce, matched or not: a mon can leave party+boxes
      # (Day Care, fusion) between request and grant — leaving its nonce in-flight
      # would block its re-request for the whole session. A later re-request with
      # the same persisted nonce is server-deduped and returns the same uid.
      by_nonce.each_key { |n| @inflight.delete(n) }
      PEMK.log("mon: granted #{applied}/#{by_nonce.size} uids")
      PEMK::Sync.mark_mon if applied > 0   # the projection just changed (uids filled in)
    end

    # Party-only projection (uid may be nil while a mint is in flight — legal).
    def projection
      return nil unless $player&.party

      $player.party.map { |p| { :uid => p.pemk_uid, :species => p.species, :level => p.level } }
    rescue => e
      PEMK.log("mon: projection error: #{e.class}: #{e.message}")
      nil
    end

    # :mon_ack is telemetry — log a server flag; nothing is ever written back.
    def on_ack(msg)
      PEMK.log("mon: server flagged party (seq #{msg[:seq]})") if msg && msg[:flagged]
    end
  end
end

# --- flag-only latency aliases --------------------------------------------------
# The event-time sweep is the catch-all; these only shorten the window between a
# common acquisition and the next flush (flush_event fires on map/badge/save only).
# Completeness deliberately does not matter here.
unless defined?(pemk_orig_pbStorePokemon)
  alias pemk_orig_pbStorePokemon pbStorePokemon
  def pbStorePokemon(pkmn)
    ret = pemk_orig_pbStorePokemon(pkmn)
    (PEMK::Sync.mark_mon rescue nil)
    ret
  end

  alias pemk_orig_pbAddToPartySilent pbAddToPartySilent
  def pbAddToPartySilent(pkmn, level = nil, see_form = true)
    ret = pemk_orig_pbAddToPartySilent(pkmn, level, see_form)
    (PEMK::Sync.mark_mon rescue nil)
    ret
  end

  alias pemk_orig_pbGenerateEgg pbGenerateEgg
  def pbGenerateEgg(pkmn, text = "")
    ret = pemk_orig_pbGenerateEgg(pkmn, text)
    (PEMK::Sync.mark_mon rescue nil)
    ret
  end
end
