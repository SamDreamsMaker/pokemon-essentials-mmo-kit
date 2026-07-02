require "minitest/autorun"
require_relative "../../protocol/pemk_wire"

# Mirrors the mkxp-z plugin's codec test: proves the extracted PEMK::Wire codec
# round-trips legacy + split frames, that the primitive codec handles the whole
# primitive set, rejects hostile/oversized input, and that the host path
# (allow_legacy=false) refuses legacy whole-Marshal frames.
class WireTest < Minitest::Test
  W = PEMK::Wire

  def payload(frame)
    frame.byteslice(4, frame.bytesize - 4)
  end

  def test_legacy_roundtrip_and_byte_identity
    msg = { type: :battle_choice, from: 509619176, to: 42, cmd: [1, 2, -1], name: "Éléonore", flag: true }
    dec = W.decode_envelope(payload(W.encode(msg)))
    assert_equal msg, dec[:env]
    assert_nil dec[:body]
    assert_equal([Marshal.dump(msg).bytesize].pack("N") + Marshal.dump(msg), W.encode(msg))
  end

  def test_split_roundtrip_with_and_without_body
    body = Marshal.dump({ arbitrary: "opaque", n: 7 })
    dec = W.decode_envelope(payload(W.encode_split({ type: :save, account_id: 42 }, body)))
    assert_equal({ type: :save, account_id: 42 }, dec[:env])
    assert_equal body, dec[:body]

    dec2 = W.decode_envelope(payload(W.encode_split({ type: :pos, x: 1 })))
    assert_equal({ type: :pos, x: 1 }, dec2[:env])
    assert_nil dec2[:body]
  end

  def test_primitive_codec_roundtrips
    [nil, true, false, 0, -5, 1_000_000_000, 2**70, 3.14159, -2.5,
     "ascii", "accénts €", :a_symbol, [], {}, [1, [2, [3]]],
     { k: [:x, 1, "y"], 99 => nil }].each do |v|
      rt = W.decode_primitive(W.encode_primitive(v))
      v.nil? ? assert_nil(rt) : assert_equal(v, rt, "roundtrip #{v.inspect}")
    end
  end

  def test_hostile_object_envelope_rejected
    evil = "\x00".b + [Marshal.dump(Object.new).bytesize].pack("N") + Marshal.dump(Object.new)
    assert_nil W.decode_envelope(evil)
  end

  def test_garbage_and_caps
    assert_nil W.decode_envelope("\x00\x00\x01".b)
    assert_nil W.decode_envelope("".b)
    assert_nil W.decode_primitive(W.encode_primitive(Array.new(W::PRIM_MAX_ELEMS + 1, 0)))
    assert_nil W.decode_envelope(payload(W.encode_split({ blob: "x" * (W::ENVELOPE_MAX + 10) })))
  end

  def test_host_rejects_legacy_accepts_split
    assert_nil W.decode_envelope(payload(W.encode({ type: :pos })), false)
    dec = W.decode_envelope(payload(W.encode_split({ type: :pos, x: 1 })), false)
    assert_equal({ type: :pos, x: 1 }, dec[:env])
  end
end
