#===============================================================================
# PEMK :: Config
#-------------------------------------------------------------------------------
# Central configuration for the MMO layer. Kept tiny and dependency-free so it
# loads first (alphanumerically) and can be read by every other module.
#===============================================================================
module PEMK
  module Config
    # Master switch. When false, the plugin loads but stays completely inert,
    # so the game behaves exactly like vanilla Essentials.
    ENABLED = true

    # Role of this game instance:
    #   :auto   - try to host; if the port is already taken (another instance is
    #             hosting on this PC), automatically join it as a client.
    #             => launch the game twice for a zero-config local test.
    #   :host   - host the relay AND play (friends connect to your LAN IP).
    #   :client - join a host at HOST:PORT.
    #   :off    - fully disabled (vanilla behaviour).
    ROLE = :auto

    # Client connect target (the host's IP). Loopback for a same-PC test; set to
    # the host's LAN IP for :client instances playing with friends.
    HOST = "127.0.0.1"
    PORT = 9998

    # Address the host relay binds to. "127.0.0.1" keeps it same-PC only and
    # avoids a Windows Firewall prompt; use "0.0.0.0" to accept LAN friends.
    BIND_HOST = "127.0.0.1"

    # How often (in frames) an idle player re-announces its position, so players
    # who join later still see everyone. ~30 frames ≈ 0.5 s.
    HEARTBEAT_FRAMES = 30

    # Drop a remote player we haven't heard from for this many seconds (covers
    # disconnects/crashes without needing the dumb relay to send leave events).
    # Must be comfortably larger than the heartbeat interval.
    PRESENCE_TIMEOUT = 3.0

    # Any of the above (ROLE/HOST/PORT/BIND_HOST) can be overridden at runtime by
    # a plain-text "mmo_config.txt" in the game folder — see the plugin README.
    # That lets friends set up LAN play without editing Ruby.
    CONFIG_FILE = "mmo_config.txt"

    # Phase 2 — authoritative account messages the SERVER handles itself (login,
    # save, economy mutations) instead of relaying. Everything else (presence)
    # is broadcast as-is.
    ACCOUNT_TYPES = [:login, :save, :mutate, :badge, :inv].freeze

    # Seconds to wait for the server's login response before proceeding offline.
    LOGIN_TIMEOUT = 15.0

    # M4 Layer C: seconds the client blocks for a server pickup grant before giving
    # up (leaves the item ball, retries later). Short — a normal grant is a few frames
    # on LAN; a laggy link tops out here rather than hanging the pickup.
    PICKUP_GRANT_TIMEOUT = 2.5

    # Wire framing: a big-endian uint32 length prefix precedes each payload.
    # Must stay in sync with the server. (Validated in Phase 0: sockets + this
    # framing round-trip correctly under mkxp-z / MRI 3.1.3.)
    LENGTH_BYTES      = 4
    MAX_MESSAGE_BYTES = 16 << 20  # 16 MiB hard cap. Larger frames = protocol error
                                  # (drop the link). Sized to fit a full game save,
                                  # which Phase 2 pushes to the server on Game.save.

    # Wire hardening (see MessageCodec's split "safe envelope + opaque body" shape).
    # ENVELOPE_MAX bounds the primitive envelope a host will decode; PRIM_MAX_ELEMS
    # bounds any Array/Hash element count in the primitive codec (anti-memory-bomb).
    ENVELOPE_MAX   = 64 << 10     # 64 KiB — routing/control data only, never a graph
    PRIM_MAX_ELEMS = 4_096
  end
end
