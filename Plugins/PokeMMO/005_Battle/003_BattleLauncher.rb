#===============================================================================
# PokeMMO :: BattleLauncher  (Phase 4b.2 / 4c.3 — start the battle)
#-------------------------------------------------------------------------------
# Launches a battle from an accepted challenge, faithfully replicating the engine
# path (TrainerBattle.start_core) but WITHOUT touching the core scripts and
# WITHOUT any side effects on the real save:
#   - both teams fight on Marshal COPIES, so neither real party is mutated;
#   - internalBattle = false, no Exp / money / Pokédex writes;
#   - pbBattleAnimation wraps the battle, giving the proper intro transition and
#     all the post-battle cleanup (BGM/BGS restore, in_battle reset, fade back)
#     for free — so after_battle (which only heals the real party) is not needed.
#
# 4c.3: role decides the battle CLASS — HostBattle (authoritative, will record)
# vs ClientBattle (will replay the host's stream). Both are still plain Battle
# subclasses here (opponent AI, each client runs its own battle); real remote
# choices are 4c.4 and deterministic streaming is 4c.5.
#===============================================================================
module PokeMMO
  module BattleLauncher
    module_function

    def deep_copy(obj)
      Marshal.load(Marshal.dump(obj))
    end

    # PvP entry: the relay owner is the HOST, the other the CLIENT.
    def start_pvp(remote)
      host  = PokeMMO::BattleNet.host?
      klass = host ? PokeMMO::HostBattle : PokeMMO::ClientBattle
      PokeMMO.log("battle: PvP start as #{host ? 'HOST' : 'CLIENT'}")
      run_battle(remote, klass)
    end

    # Single-player fallback (4b.2): fight an AI stand-in of the opponent's team.
    def start_vs_ai(remote)
      run_battle(remote, Battle)
    end

    # remote = { :name => String, :party => [Pokemon, ...] }
    def run_battle(remote, klass = Battle)
      return false unless $player && remote.is_a?(Hash) && remote[:party].is_a?(Array)
      if $player.able_pokemon_count == 0
        pbMessage(_INTL("You have no Pokémon able to battle!"))
        return false
      end
      foe_party = remote[:party].map { |pk| deep_copy(pk) }.select { |pk| pk.is_a?(Pokemon) }
      if foe_party.none? { |pk| pk && !pk.egg? && pk.hp > 0 }
        pbMessage(_INTL("{1} has no Pokémon able to battle!", remote[:name] || "?"))
        return false
      end
      foe_name = remote[:name].to_s.strip
      foe_name = "Rival" if foe_name.empty?
      ttype = remote[:trainer_type]
      ttype = $player.trainer_type unless ttype && (GameData::TrainerType.try_get(ttype) rescue nil)
      foe = NPCTrainer.new(foe_name, ttype)   # the REMOTE player's trainer type -> correct opponent sprite
      foe.party = foe_party
      my_party = $player.party.map { |pk| deep_copy(pk) }    # battle on copies, real party untouched

      scene  = BattleCreationHelperMethods.create_battle_scene
      battle = klass.new(scene, my_party, foe_party, [$player], [foe])
      battle.party1starts   = [0]
      battle.party2starts   = [0]
      battle.ally_items     = []
      battle.items          = [foe.items]
      battle.internalBattle = false   # no Pokédex / Pokérus / $player writes
      battle.expGain        = false
      battle.moneyGain      = false
      battle.canLose        = true    # a loss just ends the battle, no black-out
      battle.pokemmo_peer_id = remote[:id] if battle.respond_to?(:pokemmo_peer_id=)

      $game_temp.clear_battle_rules
      $game_temp.add_battle_rule("single")
      $game_temp.add_battle_rule("canLose")
      $game_temp.add_battle_rule("noexp")
      $game_temp.add_battle_rule("nomoney")
      BattleCreationHelperMethods.prepare_battle(battle)
      $game_temp.clear_battle_rules

      cls = klass.name.to_s.split("::").last
      PokeMMO.log("battle: starting vs #{foe_name} (#{foe_party.length} Pokemon, #{cls})")
      PokeMMO::BattleNet.reset   # drop any stale battle packets before this battle
      outcome = 0
      bgm = (pbGetTrainerBattleBGM([foe]) rescue nil)
      pbBattleAnimation(bgm, 1, [foe]) do
        pbSceneStandby { outcome = battle.pbStartBattle }
      end
      Input.update
      $game_player.straighten
      PokeMMO.log("battle: ended (outcome=#{outcome})")
      outcome
    rescue => e
      PokeMMO.log("battle: run_battle error: #{e.class}: #{e.message}")
      (e.backtrace || []).first(8).each { |l| PokeMMO.log("battle:   #{l}") }
      false
    end
  end
end
