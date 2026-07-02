#===============================================================================
# PEMK :: BattleRngSync  (Phase 4c.5 — shared authoritative RNG stream)
#-------------------------------------------------------------------------------
# Makes the two mirrored battles byte-identical. The HOST is the single source of
# randomness: every pbRandom result is recorded and the unsent tail is flushed to
# the client at round boundaries (after the send-out intro, and after each round).
# The CLIENT never calls rand — it replays the host's values in order, and when
# its replay buffer underflows it block-polls (per frame, via the 4c.1 pump)
# until the next chunk arrives. This is exactly the RecordedBattle record/replay
# pattern, streamed instead of pre-serialised.
#
# The stream is a single monotonic sequence (not keyed per round), so intro RNG
# (send-out abilities) and per-round RNG all ride the same ordered FIFO — TCP
# keeps host->relay->client order, so the client's buffer is always correct.
#
# NOTE (4c.5 scope): move outcomes are now identical on both screens. Mid-round
# replacement switches after a faint are NOT synced yet (that is 4c.6), so a
# clean end-to-end test uses one Pokémon per side; multi-Pokémon battles stay in
# sync until the first faint-induced switch.
#===============================================================================
module PEMK
  module BattleRngSync
    def pbRandom(x = 65_536)
      if PEMK::BattleNet.host?
        ret = super
        (@pokemmo_rng_log ||= []).push(ret)
        ret
      else
        @pokemmo_rng_buf ||= []
        @pokemmo_rng_cur ||= 0
        while @pokemmo_rng_cur >= @pokemmo_rng_buf.length
          pkt = PEMK::BattleNet.take_round
          if pkt
            @pokemmo_rng_buf.concat(pkt[:rng] || [])
          else
            return 0 if @decision != 0
            endpkt = PEMK::BattleNet.take_end
            if endpkt
              @decision = (endpkt[:decision] && endpkt[:decision] != 0) ? endpkt[:decision] : 5
              return 0   # host has ended: stop replaying and let the loop finish
            end
            if !(PEMK.client && PEMK.client.connected?)
              PEMK.log("battle: RNG stream starved (peer gone) -> abort")
              @decision = 5
              return 0
            end
            @scene.pbUpdate   # per-frame block-poll; keeps graphics/input + pump alive
          end
        end
        ret = @pokemmo_rng_buf[@pokemmo_rng_cur]
        @pokemmo_rng_cur += 1
        ret || 0
      end
    end

    # HOST only: ship every RNG value generated since the last flush.
    def pokemmo_flush_rng
      return unless PEMK::BattleNet.host?
      log  = (@pokemmo_rng_log ||= [])
      sent = (@pokemmo_rng_sent ||= 0)
      return if log.length <= sent
      PEMK::BattleNet.send_round(@pokemmo_peer_id, @pokemmo_round || 0,
                                    { :rng => log[sent..-1], :decision => @decision })
      @pokemmo_rng_sent = log.length
    end

    # Ship the send-out intro RNG before the first round begins; on the way out,
    # the host flushes the last RNG and tells the client the battle is over so a
    # lagging client can never hang waiting for a round/choice that won't come.
    def pbBattleLoop
      pokemmo_flush_rng
      super
      if PEMK::BattleNet.host?
        pokemmo_flush_rng
        PEMK::BattleNet.send_end(@pokemmo_peer_id, @decision)
        PEMK.log("battle: host sent :battle_end (decision=#{@decision})")
      end
    end

    # Ship this round's RNG (attack phase + end-of-round) once it is generated.
    def pbEndOfRoundPhase
      super
      pokemmo_flush_rng
    end
  end

  class HostBattle;   include BattleRngSync; end
  class ClientBattle; include BattleRngSync; end
end
