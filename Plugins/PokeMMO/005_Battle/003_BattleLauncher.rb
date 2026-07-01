#===============================================================================
# PokeMMO :: BattleLauncher  (Phase 4b.2 — start the battle)
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
# 4b.2 stand-in: the opponent's team is AI-controlled and each client runs its
# own battle. Making it one shared, host-authoritative battle (real remote
# choices, deterministic replay) is Phases 4c/4d.
#===============================================================================
module PokeMMO
  module BattleLauncher
    module_function

    def deep_copy(obj)
      Marshal.load(Marshal.dump(obj))
    end

    # remote = { :name => String, :party => [Pokemon, ...] }
    def start_vs_ai(remote)
      return false unless $player && remote.is_a?(Hash) && remote[:party].is_a?(Array)
      if $player.able_pokemon_count == 0
        pbMessage(_INTL("You have no Pokémon able to battle!"))
        return false
      end
      foe_party = remote[:party].map { |pk| deep_copy(pk) }.select { |pk| pk.is_a?(Pokemon) }
      return false if foe_party.empty?
      foe_name = remote[:name].to_s.strip
      foe_name = "Rival" if foe_name.empty?
      foe = NPCTrainer.new(foe_name, $player.trainer_type)   # player's type = a guaranteed-valid placeholder
      foe.party = foe_party
      my_party = $player.party.map { |pk| deep_copy(pk) }    # battle on copies, real party untouched

      scene  = BattleCreationHelperMethods.create_battle_scene
      battle = Battle.new(scene, my_party, foe_party, [$player], [foe])
      battle.party1starts   = [0]
      battle.party2starts   = [0]
      battle.ally_items     = []
      battle.items          = [foe.items]
      battle.internalBattle = false   # no Pokédex / Pokérus / $player writes
      battle.expGain        = false
      battle.moneyGain      = false
      battle.canLose        = true    # a loss just ends the battle, no black-out

      $game_temp.clear_battle_rules
      $game_temp.add_battle_rule("single")
      $game_temp.add_battle_rule("canLose")
      $game_temp.add_battle_rule("noexp")
      $game_temp.add_battle_rule("nomoney")
      BattleCreationHelperMethods.prepare_battle(battle)
      $game_temp.clear_battle_rules

      PokeMMO.log("battle: starting vs #{foe_name} (#{foe_party.length} Pokemon)")
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
      PokeMMO.log("battle: start_vs_ai error: #{e.class}: #{e.message}")
      (e.backtrace || []).first(8).each { |l| PokeMMO.log("battle:   #{l}") }
      false
    end
  end
end
