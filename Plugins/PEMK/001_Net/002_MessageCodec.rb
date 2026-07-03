#===============================================================================
# PEMK :: MessageCodec
#-------------------------------------------------------------------------------
# The single serialisation boundary between the wire and the rest of the SDK.
#
# Wire format:  [uint32 big-endian TOTAL length][payload bytes]
# The payload has one of two shapes, distinguished by its first byte:
#
#   LEGACY (whole-Marshal): payload = Marshal.dump(Hash). Starts with 0x04 (the
#     Marshal version marker), so it never collides with the split shape. This is
#     byte-identical to the original format and is what unmigrated senders emit.
#
#   SPLIT (safe envelope + opaque body): payload =
#       [0x00 SPLIT_MAGIC][uint32 env_len][primitive-encoded envelope][body bytes]
#     The envelope is encoded with the SELF-CONTAINED PRIMITIVE CODEC below — NOT
#     Marshal — so decoding it can only ever construct nil/bool/Integer/Float/
#     String/Symbol/Array/Hash. The body is copied verbatim and is NEVER decoded
#     in transit; only the addressed recipient Marshal-loads it.
#
# ⚠ SECURITY / TRUST BOUNDARY:
#   Marshal.load on attacker-controlled bytes can instantiate arbitrary objects
#   and is a remote-code-execution vector. All wire traffic is now split frames:
#   the HOST decodes only the primitive envelope (RCE-safe by construction — it
#   builds no classes) and rejects legacy whole-Marshal frames, so no client frame
#   can instantiate a class on the host. Deep graphs (party / save) ride as opaque
#   bodies that transit un-decoded and stay Marshal (so they need no per-class
#   serialisation to maintain across upstream updates). The remaining Marshal.load
#   of a body happens only on the addressed CLIENT, on data it is entitled to
#   (its own save, or a peer's team it is about to battle) — the accepted residual.
#   #decode (whole-Marshal) is now used only by the client's permissive path.
#===============================================================================
module PEMK
  module MessageCodec
    module_function

    # First payload byte of a split frame. A Marshal payload always starts with
    # 0x04, so the legacy and split shapes are unambiguously distinguishable.
    SPLIT_MAGIC = 0

    # msg (Hash) -> full frame. Legacy whole-Marshal shape (byte-identical to the
    # original format); used until a sender is migrated to the split shape.
    def encode(msg)
      frame(Marshal.dump(msg))
    end

    # msg (Hash of primitives) + optional opaque body (raw bytes) -> full frame.
    # The envelope goes through the primitive codec (never Marshal); the body is
    # copied verbatim and only ever Marshal-loaded by the recipient, never here.
    def encode_split(msg, body = nil)
      env = encode_primitive(msg)
      frame([SPLIT_MAGIC].pack("C") + [env.bytesize].pack("N") + env + (body || "".b))
    end

    # Legacy whole-message decode (Marshal.load) -> Hash, or nil. Trusted/local or
    # legacy-wire callers only; the hardened wire path uses #decode_envelope.
    def decode(payload)
      Marshal.load(payload)
    rescue
      nil
    end

    # payload bytes -> { :env => Hash, :body => String|nil }, or nil on any error.
    # Split frames decode the envelope with the primitive codec (safe) and return
    # the body as raw, UNLOADED bytes. When +allow_legacy+ is true, a legacy
    # whole-Marshal frame is still accepted (env = the whole message, body = nil);
    # the HOST passes false so no untrusted whole-Marshal decode path remains there.
    def decode_envelope(payload, allow_legacy = true)
      return nil if payload.nil? || payload.empty?
      if payload.getbyte(0) == SPLIT_MAGIC
        return nil if payload.bytesize < 5
        env_len = payload.byteslice(1, 4).unpack1("N")
        return nil if env_len > Config::ENVELOPE_MAX
        body_at = 5 + env_len
        return nil if body_at > payload.bytesize
        env = decode_primitive(payload.byteslice(5, env_len))
        return nil unless env.is_a?(Hash)
        body = payload.byteslice(body_at, payload.bytesize - body_at)
        { :env => env, :body => (body && !body.empty? ? body : nil) }
      elsif allow_legacy
        env = decode(payload)
        return nil unless env.is_a?(Hash)
        { :env => env, :body => nil }
      else
        nil   # legacy whole-Marshal frame rejected on the hardened (host) path
      end
    rescue
      nil
    end

    # Prefix a payload with its big-endian uint32 length.
    def frame(payload)
      [payload.bytesize].pack("N") + payload
    end

    #---------------------------------------------------------------------------
    # Self-contained primitive codec. Encodes/decodes ONLY nil, true, false,
    # Integer, Float, String, Symbol, Array and Hash. The decoder can construct
    # nothing else, so decoding hostile bytes cannot instantiate an arbitrary
    # class or run a _load/marshal_load gadget — RCE-safe by construction, and
    # tied to no game class (so upstream changes never touch it).
    #---------------------------------------------------------------------------
    PRIM_MAX_DEPTH = 32

    def encode_primitive(v)
      out = "".b
      write_primitive(out, v)
      out
    end

    def decode_primitive(bytes)
      r = Reader.new(bytes)
      v = read_primitive(r, 0)
      r.eof? ? v : nil    # reject trailing garbage
    rescue
      nil
    end

    def write_primitive(out, v)
      case v
      when nil     then out << "N"
      when true    then out << "T"
      when false   then out << "F"
      when Integer then s = v.to_s;   out << "i" << [s.bytesize].pack("N") << s
      when Float   then s = v.to_s;   out << "f" << [s.bytesize].pack("N") << s
      when Symbol  then s = v.to_s.b; out << "y" << [s.bytesize].pack("N") << s
      when String  then s = v.b;      out << "s" << [s.bytesize].pack("N") << s
      when Array
        out << "a" << [v.size].pack("N")
        v.each { |e| write_primitive(out, e) }
      when Hash
        out << "h" << [v.size].pack("N")
        v.each { |k, val| write_primitive(out, k); write_primitive(out, val) }
      else
        raise "non-primitive #{v.class}"
      end
    end

    def read_primitive(r, depth)
      raise "depth" if depth > PRIM_MAX_DEPTH
      case r.take(1)
      when "N" then nil
      when "T" then true
      when "F" then false
      when "i" then Integer(r.take(r.u32), 10)
      when "f" then Float(r.take(r.u32))
      when "y" then r.take(r.u32).force_encoding("UTF-8").to_sym
      when "s" then r.take(r.u32).force_encoding("UTF-8")
      when "a"
        n = r.u32
        raise "len" if n > Config::PRIM_MAX_ELEMS
        Array.new(n) { read_primitive(r, depth + 1) }
      when "h"
        n = r.u32
        raise "len" if n > Config::PRIM_MAX_ELEMS
        h = {}
        n.times { k = read_primitive(r, depth + 1); h[k] = read_primitive(r, depth + 1) }
        h
      else
        raise "bad tag"
      end
    end

    # Minimal forward cursor over a byte string (no StringIO dependency, which is
    # not guaranteed present under mkxp-z).
    class Reader
      def initialize(s)
        @s = s.b
        @pos = 0
        @len = @s.bytesize
      end

      def take(n)
        raise "eof" if n < 0 || @pos + n > @len
        r = @s.byteslice(@pos, n)
        @pos += n
        r
      end

      def u32
        take(4).unpack1("N")
      end

      def eof?
        @pos == @len
      end
    end
  end
end
