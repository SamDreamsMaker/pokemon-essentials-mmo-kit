#===============================================================================
# PEMK :: SwimReport  (client side - mode keys, the move half)
#-------------------------------------------------------------------------------
# The server judges a swim's start by the party the client last reported (:team_check,
# 002_TeamReport.rb): a surfer needs a Pokemon knowing Surf, a diver one knowing Dive -
# the game's own rule (pbSurf, pbDive, pbSurfacing). That report left only when a Pokemon
# came or went: a move learned from an HM or a tutor, one forgotten at the Move Deleter,
# changed nothing it saw. Here a move change on a party Pokemon marks the party channel,
# and the start of a swim flushes it, so the report reaches the server before the first
# frame on the water (the same socket keeps them in order). The `swim_report` cap at
# login says a client does this; the server asks older ones for the badge alone.
#===============================================================================
class Pokemon
  unless method_defined?(:pemk_orig_learn_move)
    alias pemk_orig_learn_move learn_move
    def learn_move(move_id)
      ret = pemk_orig_learn_move(move_id)
      PEMK::SwimReport.moved(self)
      ret
    end

    alias pemk_orig_forget_move forget_move
    def forget_move(move_id)
      ret = pemk_orig_forget_move(move_id)
      PEMK::SwimReport.moved(self)
      ret
    end

    alias pemk_orig_forget_move_at_index forget_move_at_index
    def forget_move_at_index(index)
      ret = pemk_orig_forget_move_at_index(index)
      PEMK::SwimReport.moved(self)
      ret
    end

    alias pemk_orig_forget_all_moves forget_all_moves
    def forget_all_moves
      ret = pemk_orig_forget_all_moves
      PEMK::SwimReport.moved(self)
      ret
    end
  end
end

module PEMK
  module SwimReport
    module_function

    # A move changed on +pkmn+: the party channel is marked when it is the player's (a
    # trainer's or a wild Pokemon learning its moves marks nothing).
    def moved(pkmn)
      return unless $player && $player.party && $player.party.any? { |p| p.equal?(pkmn) }

      PEMK::Sync.mark_mon
    rescue StandardError => e
      PEMK.log("swim: mark error #{e.class}: #{e.message}")
    end

    # A swim starts: the party's report goes first (hash-gated: nothing if unchanged).
    def before_swim
      PEMK::Sync.flush_party
    rescue StandardError => e
      PEMK.log("swim: flush error #{e.class}: #{e.message}")
    end
  end
end

unless defined?(pemk_orig_pbStartSurfing)
  alias pemk_orig_pbStartSurfing pbStartSurfing
  def pbStartSurfing
    PEMK::SwimReport.before_swim
    pemk_orig_pbStartSurfing
  end

  alias pemk_orig_pbDive pbDive
  def pbDive
    PEMK::SwimReport.before_swim
    pemk_orig_pbDive
  end

  alias pemk_orig_pbSurfacing pbSurfacing
  def pbSurfacing
    PEMK::SwimReport.before_swim
    pemk_orig_pbSurfacing
  end
end
