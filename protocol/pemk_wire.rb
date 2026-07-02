# frozen_string_literal: true

#===============================================================================
# PEMK::Wire — the shared wire protocol (split framing + self-contained primitive
# codec). This is the SAME on-the-wire format the mkxp-z plugin speaks
# (Plugins/PEMK/001_Net/002_MessageCodec.rb); the two must stay byte-compatible
# (a CI identity check is planned). Standalone: no game classes, no PEMK::Config.
#
# Frame:  [uint32 BE total len][payload]
# Payload shapes, distinguished by first byte:
#   LEGACY (whole-Marshal): Marshal.dump(Hash), starts 0x04 — accepted only when
#                           allow_legacy is true (the server passes false).
#   SPLIT: [0x00 SPLIT_MAGIC][uint32 env_len][primitive envelope][opaque body]
#
# The envelope uses the primitive codec below (nil/bool/Integer/Float/String/
# Symbol/Array/Hash only) — decoding hostile bytes can construct nothing else, so
# it is RCE-safe by construction. Opaque bodies are never decoded here.
#===============================================================================
module PEMK
  module Wire
    module_function

    PROTOCOL_VERSION  = 1
    SPLIT_MAGIC       = 0
    LENGTH_BYTES      = 4
    MAX_MESSAGE_BYTES = 16 << 20   # 16 MiB frame hard cap
    ENVELOPE_MAX      = 64 << 10   # 64 KiB primitive-envelope cap
    PRIM_MAX_ELEMS    = 4096
    PRIM_MAX_DEPTH    = 32

    # msg (Hash) -> full frame. Legacy whole-Marshal shape (client compatibility).
    def encode(msg)
      frame(Marshal.dump(msg))
    end

    # msg (Hash of primitives) + optional opaque body -> full split frame.
    def encode_split(msg, body = nil)
      env = encode_primitive(msg)
      frame(+"\x00".b << [env.bytesize].pack("N") << env << (body || "".b))
    end

    def decode(payload)
      Marshal.load(payload)
    rescue StandardError
      nil
    end

    # payload bytes -> { env: Hash, body: String|nil } or nil. allow_legacy=false
    # rejects legacy whole-Marshal frames (the server's hardened path).
    def decode_envelope(payload, allow_legacy = true)
      return nil if payload.nil? || payload.empty?

      if payload.getbyte(0) == SPLIT_MAGIC
        return nil if payload.bytesize < 5

        env_len = payload.byteslice(1, 4).unpack1("N")
        return nil if env_len > ENVELOPE_MAX

        body_at = 5 + env_len
        return nil if body_at > payload.bytesize

        env = decode_primitive(payload.byteslice(5, env_len))
        return nil unless env.is_a?(Hash)

        body = payload.byteslice(body_at, payload.bytesize - body_at)
        { env: env, body: (body && !body.empty? ? body : nil) }
      elsif allow_legacy
        env = decode(payload)
        env.is_a?(Hash) ? { env: env, body: nil } : nil
      end
    rescue StandardError
      nil
    end

    def frame(payload)
      [payload.bytesize].pack("N") + payload
    end

    #--- self-contained primitive codec ---------------------------------------
    def encode_primitive(value)
      out = +"".b
      write_primitive(out, value)
      out
    end

    def decode_primitive(bytes)
      reader = Reader.new(bytes)
      value = read_primitive(reader, 0)
      reader.eof? ? value : nil
    rescue StandardError
      nil
    end

    def write_primitive(out, value)
      case value
      when nil     then out << "N"
      when true    then out << "T"
      when false   then out << "F"
      when Integer then s = value.to_s;   out << "i" << [s.bytesize].pack("N") << s
      when Float   then s = value.to_s;   out << "f" << [s.bytesize].pack("N") << s
      when Symbol  then s = value.to_s.b; out << "y" << [s.bytesize].pack("N") << s
      when String  then s = value.b;      out << "s" << [s.bytesize].pack("N") << s
      when Array
        out << "a" << [value.size].pack("N")
        value.each { |e| write_primitive(out, e) }
      when Hash
        out << "h" << [value.size].pack("N")
        value.each { |k, v| write_primitive(out, k); write_primitive(out, v) }
      else
        raise "non-primitive #{value.class}"
      end
    end

    def read_primitive(reader, depth)
      raise "depth" if depth > PRIM_MAX_DEPTH

      case reader.take(1)
      when "N" then nil
      when "T" then true
      when "F" then false
      when "i" then Integer(reader.take(reader.u32), 10)
      when "f" then Float(reader.take(reader.u32))
      when "y" then reader.take(reader.u32).force_encoding("UTF-8").to_sym
      when "s" then reader.take(reader.u32).force_encoding("UTF-8")
      when "a"
        n = reader.u32
        raise "len" if n > PRIM_MAX_ELEMS

        Array.new(n) { read_primitive(reader, depth + 1) }
      when "h"
        n = reader.u32
        raise "len" if n > PRIM_MAX_ELEMS

        h = {}
        n.times { k = read_primitive(reader, depth + 1); h[k] = read_primitive(reader, depth + 1) }
        h
      else
        raise "bad tag"
      end
    end

    # Minimal forward cursor over a byte string.
    class Reader
      def initialize(str)
        @s = str.b
        @pos = 0
        @len = @s.bytesize
      end

      def take(n)
        raise "eof" if n.negative? || @pos + n > @len

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
