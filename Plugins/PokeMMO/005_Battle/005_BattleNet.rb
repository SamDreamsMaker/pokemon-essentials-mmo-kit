#===============================================================================
# PokeMMO :: BattleNet  (Phase 4c.2 — battle-stream transport + inbound queue)
#-------------------------------------------------------------------------------
# The wire layer for a networked battle, kept deliberately separate from the
# battle mechanics so transport can be tested on its own. Inbound battle messages
# (routed here from Dispatch, already drained per-frame by Pump.tick) are parked
# in plain queues; the battle loops (4c.4+) poll them per frame. Nothing here
# blocks or touches the battle engine yet.
#
# Roles: the instance that owns the relay is the HOST (authoritative battle); the
# other is the CLIENT (replays the host's stream).
#
# Message types (all Hashes over the existing relay, addressed with :to/:from and
# filtered like Challenge/BattleSetup):
#   :battle_start  host->client  battle properties to build the playback battle
#   :battle_choice client->host   one human choice for a round/battler
#   :battle_round  host->client   the authoritative per-round replay packet
#   :battle_end    host->client   final decision + any post-battle rolls
#===============================================================================
module PokeMMO
  module BattleNet
    @inbox_choice = {}   # [round, idxBattler] => cmd tuple
    @inbox_round  = []   # FIFO of authoritative round/RNG packets (TCP keeps order)
    @inbox_start  = nil
    @inbox_end    = nil

    def self.host?
      !PokeMMO.relay.nil?
    end

    # Clear every queue (call at battle start and end).
    def self.reset
      @inbox_choice = {}
      @inbox_round  = []
      @inbox_start  = nil
      @inbox_end    = nil
    end

    # --- inbound: routed from Dispatch (runs inside the per-frame pump) ----------
    def self.on_message(msg)
      return unless msg[:to] == PokeMMO.self_id
      case msg[:type]
      when :battle_start  then @inbox_start = msg
      when :battle_choice then @inbox_choice[[msg[:round], msg[:idxBattler]]] = msg[:cmd]
      when :battle_round  then @inbox_round.push(msg)
      when :battle_end    then @inbox_end = msg
      end
    end

    # --- polled by the battle loops (non-blocking; nil until it has arrived) -----
    def self.take_choice(round, idx_battler)
      @inbox_choice.delete([round, idx_battler])
    end

    # Oldest authoritative packet (FIFO), or nil. The RNG stream is a single
    # ordered sequence of chunks, so the client just drains them in arrival order.
    def self.take_round
      @inbox_round.shift
    end

    def self.take_start
      m = @inbox_start
      @inbox_start = nil
      m
    end

    def self.take_end
      m = @inbox_end
      @inbox_end = nil
      m
    end

    # --- outbound helpers --------------------------------------------------------
    def self.send_start(to_id, props)
      PokeMMO.send_message({ :type => :battle_start, :from => PokeMMO.self_id,
                             :to => to_id, :props => props })
    end

    def self.send_choice(to_id, round, idx_battler, cmd)
      PokeMMO.send_message({ :type => :battle_choice, :from => PokeMMO.self_id, :to => to_id,
                             :round => round, :idxBattler => idx_battler, :cmd => cmd })
    end

    def self.send_round(to_id, round, packet)
      PokeMMO.send_message(packet.merge({ :type => :battle_round, :from => PokeMMO.self_id,
                                          :to => to_id, :round => round }))
    end

    def self.send_end(to_id, decision)
      PokeMMO.send_message({ :type => :battle_end, :from => PokeMMO.self_id,
                             :to => to_id, :decision => decision })
    end
  end
end
