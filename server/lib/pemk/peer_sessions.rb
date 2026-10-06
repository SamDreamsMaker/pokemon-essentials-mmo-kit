# frozen_string_literal: true

module PEMK
  # Who may send what to whom between two players (the relay guard): the invites
  # pending, and the sessions open - per PAIR and per KIND, so a player may battle one
  # player and trade with another, and nothing one of them does touches the other.
  #
  # An invite (a :challenge, a :trade_invite) is answered only by whom it invited: an
  # accept opens that pair's session of that kind (a trade's: its trade_id), a decline
  # drops the invite. A teardown ends its own pair's session of its own kind. Reactor
  # thread only, like @online.
  class PeerSessions
    KIND = { challenge: :battle, challenge_accept: :battle, challenge_decline: :battle,
             battle_team: :battle, battle_start: :battle, battle_choice: :battle,
             battle_round: :battle, battle_switch: :battle, battle_end: :battle,
             trade_invite: :trade, trade_accept: :trade, trade_decline: :trade,
             trade_offer: :trade, trade_lock: :trade, trade_cancel: :trade }.freeze
    INVITE_TTL = 600   # seconds an unanswered invite is kept (memory only: a prompt may wait)

    def initialize
      @invites  = {}   # [from, to, kind] => { trade_id:, at: }
      @sessions = {}   # [low, high] => { battle: true, trade: trade_id }
    end

    def self.pair(a, b) = [a, b].minmax

    def invite(from, to, kind, trade_id: nil, now: Time.now)
      @invites[[from, to, kind]] = { trade_id: trade_id, at: now }
    end

    def invited?(from, to, kind, trade_id: nil)
      inv = @invites[[from, to, kind]]
      !inv.nil? && (kind != :trade || inv[:trade_id] == trade_id)
    end

    # B answers A's invite: -> true when that invite stands (then dropped; an accept
    # opens the pair's session of that kind).
    def answer(from, to, kind, accept:, trade_id: nil)
      return false unless invited?(to, from, kind, trade_id: trade_id)

      @invites.delete([to, from, kind])
      (@sessions[self.class.pair(from, to)] ||= {})[kind] = kind == :trade ? trade_id : true if accept
      true
    end

    # The pair's session of +kind+ (a trade's with that trade_id).
    def session?(a, b, kind, trade_id: nil)
      s = @sessions[self.class.pair(a, b)]
      return false unless s && s.key?(kind)

      kind != :trade || s[:trade] == trade_id
    end

    # A teardown of +kind+ between a and b: their session of that kind (a trade's with
    # that trade_id) and their invites of it, both ways. Never anything else.
    def close(a, b, kind, trade_id: nil)
      pair = self.class.pair(a, b)
      s = @sessions[pair]
      if s && s.key?(kind) && (kind != :trade || s[:trade] == trade_id)
        s.delete(kind)
        @sessions.delete(pair) if s.empty?
      end
      [[a, b], [b, a]].each do |from, to|
        inv = @invites[[from, to, kind]]
        @invites.delete([from, to, kind]) if inv && (kind != :trade || inv[:trade_id] == trade_id)
      end
    end

    # An account's sessions closed (it left, or a relogin dropped them). Its invites stay to
    # their TTL: a client keeps a challenge across a relogin. -> [[partner, kind,
    # trade_id], ...] for the partners to tell.
    def drop_account(account_id)
      gone = []
      @sessions.delete_if do |(a, b), s|
        next false unless a == account_id || b == account_id

        partner = a == account_id ? b : a
        s.each { |kind, v| gone << [partner, kind, kind == :trade ? v : nil] }
        true
      end
      gone
    end

    def prune(now: Time.now)
      @invites.delete_if { |_, inv| now - inv[:at] > INVITE_TTL }
    end

    def size
      @invites.size + @sessions.size
    end
  end
end
