defmodule VoiceLab.Mulaw do
  import Bitwise
  @bias 0x84
  @clip 8159
  @ends [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]
  def silence_byte, do: 0xFF
  def silence(n), do: :binary.copy(<<0xFF>>, n)
  def encode_sample(sample) when is_integer(sample) do
    value = sample >>> 2
    {magnitude, mask} = if value < 0, do: {-value, 0x7F}, else: {value, 0xFF}
    magnitude = min(magnitude, @clip) + div(@bias, 4)
    case Enum.find_index(@ends, &(&1 >= magnitude)) do
      nil -> bxor(0x7F, mask)
      segment -> bxor(segment <<< 4 ||| (magnitude >>> (segment + 1) &&& 0x0F), mask)
    end
  end
  def decode_sample(byte) when byte in 0..255 do
    inverted = bnot(byte) &&& 0xFF
    magnitude = (((inverted &&& 0x0F) <<< 3) + @bias) <<< ((inverted &&& 0x70) >>> 4)
    if (inverted &&& 0x80) != 0, do: @bias - magnitude, else: magnitude - @bias
  end
  def encode(samples) when is_list(samples), do: for(s <- samples, into: <<>>, do: <<encode_sample(s)>>)
  def decode(binary) when is_binary(binary), do: for(<<b <- binary>>, do: decode_sample(b))
  def scale(frame, factor) when factor >= 0.0 and factor <= 1.0, do: for(<<b <- frame>>, into: <<>>, do: <<b |> decode_sample() |> Kernel.*(factor) |> round() |> encode_sample()>>)
end
