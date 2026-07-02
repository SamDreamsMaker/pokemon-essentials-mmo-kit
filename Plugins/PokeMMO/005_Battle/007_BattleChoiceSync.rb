#===============================================================================
# PokeMMO :: BattleChoiceSync  (Phase 4c.4 — canonical choice exchange)
#-------------------------------------------------------------------------------
# Mixed into BOTH HostBattle and ClientBattle. Each instance keeps its OWN team as
# party1 (index 0) and the opponent as party2 (index 1) — so the untouched scene
# already shows each player their own perspective (see the 4c architecture note).
# The index maps are therefore MIRRORED across the two instances: my battler at
# index i is the peer's battler at index (i ^ 1), and vice-versa.
#
# Per round, on each side:
#   - the local player picks normally for their own battler(s) (super);
#   - that choice is re-encoded as a compact index tuple (no Move objects) and
#     sent to the peer, KEYED BY THE PEER'S LOCAL INDEX for that battler (i ^ 1),
#     so the receiver polls by its own opponent index and finds it directly;
#   - the opponent battler is NOT driven by the AI — instead we poll (per frame,
#     via the already-live pump) for the peer's tuple and apply it with the same
#     pbRegister* calls the engine uses, remapping any explicit target index to
#     our mirrored frame.
#
# RNG is still unshared here, so damage rolls can differ between the two screens;
# the shared authoritative RNG stream that makes both battles byte-identical is
# Phase 4c.5. Choices are what 4c.4 proves.
#===============================================================================
module PokeMMO
  module BattleChoiceSync
    FIGHT   = 0
    BAG     = 1
    POKEMON = 2
    RUN     = 3

    WAIT_TIMEOUT_FRAMES = 3600   # ~60s at 60fps; abort rather than freeze (hardened in 4c.6)

    attr_accessor :pokemmo_peer_id

    # One monotonic round counter, incremented identically on both instances
    # (pbCommandPhase runs once per round on each), used as the exchange key.
    def pbCommandPhase
      @pokemmo_round = (@pokemmo_round || -1) + 1
      super
    end

    def pbCommandPhaseLoop(isPlayer)
      if isPlayer
        indices = pokemmo_exchange_indices(true)   # measured BEFORE choices are made
        super
        indices.each do |idx|
          cmd = pokemmo_encode_choice(idx)
          next unless cmd
          # Key by the PEER's local index for this battler (mirror: i ^ 1).
          PokeMMO::BattleNet.send_choice(@pokemmo_peer_id, @pokemmo_round, idx ^ 1, cmd)
          PokeMMO.log("battle: sent choice r=#{@pokemmo_round} idx=#{idx} #{cmd.inspect}")
        end
      else
        pokemmo_exchange_indices(false).each do |idx|
          cmd = pokemmo_wait_for_remote_choice(idx)
          break unless cmd
          pokemmo_apply_choice(idx, cmd)
          PokeMMO.log("battle: applied remote choice r=#{@pokemmo_round} idx=#{idx} #{cmd.inspect}")
        end
      end
    end

    # Battlers on the given side that will actually be prompted (not forced into a
    # locked multi-turn move). Both instances compute the same paired set, so the
    # send side and the poll side stay matched. Mirrors the engine's own skip at
    # 009_Battle_CommandPhase.rb:208.
    def pokemmo_exchange_indices(is_player)
      out = []
      @battlers.each_with_index do |b, idx|
        next if !b || pbOwnedByPlayer?(idx) != is_player
        next if @choices[idx][0] != :None || !pbCanShowCommands?(idx)
        out << idx
      end
      out
    end

    # Poll for the peer's choice for our opponent battler +idx+ (the peer sent it
    # keyed by this very index). Per-frame, no sleep/thread; aborts to a draw if
    # the peer goes silent so the battle can't freeze forever.
    def pokemmo_wait_for_remote_choice(idx)
      waited = 0
      loop do
        cmd = PokeMMO::BattleNet.take_choice(@pokemmo_round, idx)
        return cmd if cmd
        return nil if @decision != 0
        waited += 1
        if waited > WAIT_TIMEOUT_FRAMES || !(PokeMMO.client && PokeMMO.client.connected?)
          PokeMMO.log("battle: remote choice timeout/disconnect (r=#{@pokemmo_round} idx=#{idx}) -> abort")
          @decision = 5   # draw: ends the battle with no black-out (canLose=true)
          return nil
        end
        @scene.pbUpdate   # keep graphics/input + the network pump (4c.1) alive
      end
    end

    def pokemmo_encode_choice(idx)
      c = @choices[idx]
      case c[0]
      when :UseMove   then [FIGHT, c[1], c[3]]        # move index, target index (-1 in singles)
      when :SwitchOut then [POKEMON, c[1]]            # party index
      when :UseItem   then [BAG, c[1], c[2], c[3]]    # item, target, move index
      when :Run       then [RUN]
      end
    end

    def pokemmo_apply_choice(idx, cmd)
      case cmd[0]
      when FIGHT
        (cmd[1] == -1) ? pbAutoChooseMove(idx, false) : pbRegisterMove(idx, cmd[1], false)
        # An explicit target index is in the sender's frame; mirror it (i ^ 1).
        # Singles use -1 (auto-target), so this only bites in future doubles.
        pbRegisterTarget(idx, cmd[2] ^ 1) if cmd[2] && cmd[2] >= 0
      when POKEMON then pbRegisterSwitch(idx, cmd[1])
      when BAG     then pbRegisterItem(idx, cmd[1], cmd[2], cmd[3])
      when RUN     then @choices[idx] = [:Run, 0, nil, -1]
      end
    end
  end

  # Reopen the 4c.3 subclasses (defined in 006_NetBattles.rb) to mix this in.
  class HostBattle;   include BattleChoiceSync; end
  class ClientBattle; include BattleChoiceSync; end
end
