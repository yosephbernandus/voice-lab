defmodule VoiceLab.Packet do
  @version 2
  @payload_type 0
  @samples_per_frame 160
  defstruct [:sequence_number, :timestamp, :ssrc, :payload]
  def samples_per_frame, do: @samples_per_frame
  def sample_rate, do: 8_000
  def new_ssrc, do: :rand.uniform(4_294_967_296) - 1
  def pack(%__MODULE__{} = p), do: <<@version::2, 0::1, 0::1, 0::4, 0::1, @payload_type::7, p.sequence_number::16, p.timestamp::32, p.ssrc::32, p.payload::binary>>
  def parse(<<@version::2, 0::1, 0::1, 0::4, 0::1, @payload_type::7, seq::16, ts::32, ssrc::32, payload::binary-size(@samples_per_frame)>>), do: {:ok, %__MODULE__{sequence_number: seq, timestamp: ts, ssrc: ssrc, payload: payload}}
  def parse(<<@version::2, _::1, _::1, _::4, _::1, _::7, _::16, _::32, _::32, _::binary>>), do: {:error, :invalid_payload}
  def parse(<<version::2, _::bitstring>>) when version != @version, do: {:error, :unsupported_version}
  def parse(_), do: {:error, :short_packet}
  def stream(audio, ssrc, first_sequence_number \\ 0) do
    audio |> chunks() |> Enum.with_index() |> Enum.map(fn {payload, i} -> %__MODULE__{sequence_number: rem(first_sequence_number + i, 65_536), timestamp: i * @samples_per_frame, ssrc: ssrc, payload: payload} end)
  end
  defp chunks(binary), do: (for <<frame::binary-size(@samples_per_frame) <- binary>>, do: frame)
end
