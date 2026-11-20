defmodule VoiceLab.MulawTest do
  use ExUnit.Case, async: true

  alias VoiceLab.Mulaw

  test "negative samples use arithmetic 14-bit quantization" do
    assert Mulaw.encode_sample(-1) == 0x7E
    assert Mulaw.encode_sample(-3) == 0x7E
    assert Mulaw.encode_sample(-9) == 0x7D
    assert Mulaw.encode_sample(-11) == 0x7D
    assert Mulaw.encode_sample(-19) == 0x7C
  end

  test "quantization keeps the negative sign at zero boundary" do
    encoded = Mulaw.encode([-1, 0, 1])

    assert encoded == <<0x7E, 0xFF, 0xFF>>
  end
end
