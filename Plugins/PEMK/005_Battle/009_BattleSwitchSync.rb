#===============================================================================
# PEMK :: BattleSwitchSync  (mid-round replacement switch synchronization)
#-------------------------------------------------------------------------------
# Makes multi-Pokémon battles stay in sync across a faint. Every non-random
# replacement pick funnels through Battle#pbSwitchInBetween
# (005_Battle_ActionSwitching.rb:132): the engine opens the party screen for a
# battler the local player OWNS, or runs the AI (@battleAI.pbDefaultChooseNewEnemy,
# which uses the UNSYNCED pbAIRandom) for the opponent. That AI branch is the only
# desync source — each instance would pick a different replacement for the
# opponent's fainted Pokémon.
#
# Fix, mirroring BattleChoiceSync: for MY battler, keep the real party screen and
# SEND the chosen party index to the peer; for the OPPONENT's battler, DON'T run
# the AI — WAIT (per-frame poll) for the peer's pick. The party screen and the AI
# both consume ZERO synced pbRandom, so removing the AI perturbs no draw and the
# RNG stream stays aligned. Random forced switches (Roar/Whirlwind/Dragon Tail…)
# use random=true and hit pbRandom directly, already synced by BattleRngSync —
# they never reach pbSwitchInBetween, so they are untouched here.
#
# Keying: (round, receiver-local index = idxBattler^1, seq). `seq` is a monotonic
# per-battler-index counter, so two switches of the same slot in one round
# (U-turn then a faint) get distinct keys. Because ownership is mirrored, exactly
# one instance owns (and sends for) each physical battler, so its per-index seq
# matches the peer's poll seq for the same physical Pokémon.
#===============================================================================
module PEMK
  module BattleSwitchSync
    def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
      seq = ((@pokemmo_switch_seq ||= {})[idxBattler] ||= 0)
      @pokemmo_switch_seq[idxBattler] += 1
      round = (@pokemmo_round || 0)
      if pbOwnedByPlayer?(idxBattler)
        # My battler: pick for real (party screen), then tell the peer — keyed by
        # THEIR local index for this battler (idxBattler ^ 1).
        idx = super(idxBattler, checkLaxOnly, canCancel)
        PEMK::BattleNet.send_switch(@pokemmo_peer_id, round, idxBattler ^ 1, seq, idx)
        PEMK.log("battle: sent switch r=#{round} idx=#{idxBattler} seq=#{seq} -> #{idx}")
        idx
      else
        # Opponent's battler: the peer owns it — wait for its pick, not the AI.
        idx = pokemmo_wait_for_remote_switch(round, idxBattler, seq)
        PEMK.log("battle: applied remote switch r=#{round} idx=#{idxBattler} seq=#{seq} -> #{idx}")
        idx
      end
    end

    # Per-frame poll for the peer's replacement pick (keeps graphics/input + the
    # 4c.1 pump alive; adopts :battle_end and aborts on timeout/disconnect so a
    # silent peer can't freeze the battle).
    def pokemmo_wait_for_remote_switch(round, idxBattler, seq)
      waited = 0
      loop do
        idx = PEMK::BattleNet.take_switch(round, idxBattler, seq)
        return idx unless idx.nil?
        return pokemmo_first_switchable(idxBattler) if @decision != 0
        endpkt = PEMK::BattleNet.take_end
        if endpkt
          @decision = (endpkt[:decision] && endpkt[:decision] != 0) ? endpkt[:decision] : 5
          return pokemmo_first_switchable(idxBattler)
        end
        waited += 1
        if waited > PEMK::BattleChoiceSync::WAIT_TIMEOUT_FRAMES || !(PEMK.client && PEMK.client.connected?)
          PEMK.log("battle: remote switch timeout/disconnect (r=#{round} idx=#{idxBattler}) -> abort")
          @decision = 5
          return pokemmo_first_switchable(idxBattler)
        end
        @scene.pbUpdate
      end
    end

    # Deterministic fallback used ONLY on abort — first non-fainted party member.
    # Never calls pbRandom, so the shared RNG stream is never perturbed.
    def pokemmo_first_switchable(idxBattler)
      party = (pbParty(idxBattler) rescue nil)
      return -1 unless party.is_a?(Array)
      party.each_with_index { |pk, i| return i if pk && !pk.egg? && pk.hp > 0 }
      -1
    end
  end

  # Reopen the 4c.3 subclasses to mix this in (loads after 006/007/008, so super
  # in pbSwitchInBetween resolves to the core Battle#pbSwitchInBetween).
  class HostBattle;   include BattleSwitchSync; end
  class ClientBattle; include BattleSwitchSync; end
end
