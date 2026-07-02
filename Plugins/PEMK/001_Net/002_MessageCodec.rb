#===============================================================================
# PEMK :: MessageCodec
#-------------------------------------------------------------------------------
# The single serialisation boundary between the wire and the rest of the SDK.
# Turning this into a swappable strategy (Marshal now, typed-JSON later) keeps
# the transport and game code independent of the encoding.
#
# Wire format:  [uint32 big-endian payload length][payload bytes]
# Payload:      Marshal.dump of a plain Ruby Hash. Marshal is used because
#               Phase 0 proved the `json` stdlib is ABSENT under this mkxp-z
#               build (LoadError), while Marshal is a native language feature.
#
# ⚠ SECURITY / TRUST BOUNDARY — read before exposing this to untrusted peers:
#   Marshal.load on attacker-controlled bytes can instantiate arbitrary objects
#   and is a remote-code-execution vector. This is acceptable ONLY for the
#   Phase 1 walking skeleton (a trusted host + friends on a LAN). Before any
#   authoritative or public deployment it MUST be replaced by a validated codec
#   — a vendored typed-JSON, or a class-whitelisted loader. Tracked in the
#   architecture doc (§4 wire-format, §10-G9).
#===============================================================================
module PEMK
  module MessageCodec
    module_function

    # msg (Hash) -> frame (binary String, length-prefixed)
    def encode(msg)
      payload = Marshal.dump(msg)
      [payload.bytesize].pack("N") + payload
    end

    # payload bytes -> msg (Hash), or nil if the bytes cannot be decoded.
    def decode(payload)
      Marshal.load(payload)
    rescue => e
      # Corrupt/garbage frame: never let a bad packet raise into the caller.
      nil
    end
  end
end
