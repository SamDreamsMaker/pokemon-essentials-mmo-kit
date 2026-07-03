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
      # A per-instance uniqueness token, NOT a security value — plain rand is fine
      # (62-bit collision odds are negligible, and it is scoped to one account on
      # the server's UNIQUE(issuer, nonce) index). SecureRandom isn't loaded under
      # mkxp-z, so don't reference it.
      rand(2**62) + 1
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

    # --- M3.2 trade helpers -----------------------------------------------------

    # Find the owned instance carrying +uid+ (party or any box). -> Pokemon | nil.
    def find_by_uid(uid)
      return nil unless uid

      each_owned { |p| return p if p.pemk_uid == uid }
      nil
    end

    # Remove the instance with +uid+ from party (kept COMPACT) or a box slot.
    # -> true if removed.
    def remove_by_uid(uid)
      return false unless uid && $player&.party

      idx = $player.party.index { |p| p && p.pemk_uid == uid }
      if idx
        $player.party.delete_at(idx)
        return true
      end
      storage = $PokemonStorage
      return false unless storage&.boxes

      storage.boxes.each do |box|
        next unless box
        box.length.times do |si|
          p = box[si]
          if p && p.pemk_uid == uid
            box[si] = nil                # empty the slot
            return true
          end
        end
      end
      false
    end

    # Login enforcement (M3.2): drop uids this account traded away and no longer
    # owns (the server's positive eviction list). NEVER touches nil-uid mons.
    def evict(list)
      return unless list.is_a?(Array)

      removed = 0
      list.each do |uid|
        next unless uid.is_a?(Integer) && uid.positive?
        removed += 1 if remove_by_uid(uid)
      end
      PEMK.log("mon: evicted #{removed}/#{list.size} traded-away uid(s)") if removed.positive?
    rescue => e
      PEMK.log("mon: evict error: #{e.class}: #{e.message}")
    end

    # Silently add a mon received in a trade: it KEEPS its transferred pemk_uid
    # (server-owned by us now) but drops the sender's pemk_nonce. Party if room,
    # else a box. No pbMessage/nickname prompt.
    def materialize(pkmn)
      return false unless pkmn.is_a?(Pokemon) && $player

      pkmn.pemk_nonce = nil
      if $player.party.length < Settings::MAX_PARTY_SIZE
        $player.party[$player.party.length] = pkmn
      elsif $PokemonStorage
        ($PokemonStorage.pbStoreCaught(pkmn) rescue nil)
      end
      true
    rescue => e
      PEMK.log("mon: materialize error: #{e.class}: #{e.message}")
      false
    end
  end
end

# --- acquisition latency aliases ------------------------------------------------
# The event-time sweep is the catch-all for UID minting; these shorten the window
# between a common acquisition and the next flush. They ALSO arm an URGENT
# checkpoint (:pokemon) — gaining a Pokémon is high-value and must be persisted
# within ~1s, not the ambient 20s floor (a quick close otherwise loses it; mkxp-z
# gives no reliable exit hook). pbStorePokemon is the box path (catch / debug
# clone / gift-when-party-full); pbAddPokemon/pbAddToParty are aliased in 007.
unless defined?(pemk_orig_pbStorePokemon)
  alias pemk_orig_pbStorePokemon pbStorePokemon
  def pbStorePokemon(pkmn)
    ret = pemk_orig_pbStorePokemon(pkmn)
    (PEMK::Sync.mark_mon rescue nil)
    (PEMK::Checkpoint.request(:pokemon) rescue nil)
    ret
  end

  alias pemk_orig_pbAddToPartySilent pbAddToPartySilent
  def pbAddToPartySilent(pkmn, level = nil, see_form = true)
    ret = pemk_orig_pbAddToPartySilent(pkmn, level, see_form)
    (PEMK::Sync.mark_mon rescue nil)
    (PEMK::Checkpoint.request(:pokemon) rescue nil) if ret
    ret
  end

  alias pemk_orig_pbGenerateEgg pbGenerateEgg
  def pbGenerateEgg(pkmn, text = "")
    ret = pemk_orig_pbGenerateEgg(pkmn, text)
    (PEMK::Sync.mark_mon rescue nil)
    (PEMK::Checkpoint.request(:pokemon) rescue nil) if ret
    ret
  end
end
