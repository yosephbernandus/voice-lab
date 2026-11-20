defmodule VoiceLab.Fixture do
  defstruct [:path, :pcm, :sample_rate]
  def load(path) do
    case VoiceLab.Wav.read(path) do
      {:ok, %{sample_rate: rate}, pcm} -> {:ok, %__MODULE__{path: path, pcm: pcm, sample_rate: rate}}
      {:error, reason} -> {:error, reason}
    end
  end
  def from_pcm(pcm, path \\ "fixture") when is_binary(pcm), do: %__MODULE__{path: path, pcm: pcm, sample_rate: 8_000}
end
