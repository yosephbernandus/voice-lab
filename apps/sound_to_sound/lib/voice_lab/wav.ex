defmodule VoiceLab.Wav do
  @moduledoc "Reads and writes mono 16-bit PCM RIFF/WAVE fixtures."
  def read(path) do
    with {:ok, contents} <- File.read(path), {:ok, chunks} <- parse_container(contents), {:ok, metadata} <- parse_format(chunks["fmt "]), {:ok, pcm} <- fetch_audio(chunks), do: {:ok, metadata, pcm}
  end
  def write(path, pcm, sample_rate) when is_binary(pcm) and rem(byte_size(pcm), 2) == 0 and sample_rate > 0 do
    format = <<1::little-16, 1::little-16, sample_rate::little-32, sample_rate * 2::little-32, 2::little-16, 16::little-16>>
    body = chunk("fmt ", format) <> chunk("data", pcm)
    File.write(path, <<"RIFF", byte_size(body) + 4::little-32, "WAVE", body::binary>>)
  end
  defp parse_container(<<"RIFF", _::little-32, "WAVE", chunks::binary>>), do: parse_chunks(chunks, %{})
  defp parse_container(_), do: {:error, :invalid_wav}
  defp parse_chunks(<<>>, chunks), do: {:ok, chunks}
  defp parse_chunks(<<id::binary-size(4), size::little-32, rest::binary>>, chunks) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest
    remaining = if rem(size, 2) == 1 and byte_size(remaining) > 0, do: binary_part(remaining, 1, byte_size(remaining) - 1), else: remaining
    parse_chunks(remaining, Map.put_new(chunks, id, data))
  end
  defp parse_chunks(_, _), do: {:error, :invalid_wav}
  defp parse_format(<<1::little-16, 1::little-16, rate::little-32, _::little-32, 2::little-16, 16::little-16, _::binary>>), do: {:ok, %{sample_rate: rate, channels: 1, bits_per_sample: 16}}
  defp parse_format(_), do: {:error, :unsupported_audio_format}
  defp fetch_audio(%{"data" => pcm}) when rem(byte_size(pcm), 2) == 0, do: {:ok, pcm}
  defp fetch_audio(_), do: {:error, :invalid_wav}
  defp chunk(id, data), do: <<id::binary-size(4), byte_size(data)::little-32, data::binary, (if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>) :: binary>>
end
