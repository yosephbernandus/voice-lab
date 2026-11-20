defmodule VoiceLab.Pipeline do
  alias VoiceLab.{Concealment, Fixture, Impairment, JitterBuffer, Mulaw, Packet}
  defmodule Result, do: defstruct [:policy, :strategy, :fixture, :rendered_pcm, :statistics]
  def run(%Fixture{} = f, %Impairment.Policy{} = policy, strategy \\ :silence) do
    packets = encode(f); delivered = Impairment.deliver(packets, policy)
    buffer = Enum.reduce(delivered, JitterBuffer.new(first_sequence_number: hd(packets).sequence_number), &JitterBuffer.push(&2, &1))
    {outcomes, buffer} = Enum.map_reduce(1..length(packets), buffer, fn _, b -> JitterBuffer.pop(b, :end_of_stream) end)
    {mulaw, concealed} = Concealment.render(outcomes, strategy)
    stats = buffer.statistics |> Map.merge(%{sent: length(packets), dropped: length(packets) - buffer.statistics.received, concealed: concealed})
    %Result{policy: policy, strategy: strategy, fixture: f.path, rendered_pcm: decode(mulaw), statistics: stats}
  end
  def encode(%Fixture{pcm: pcm}) do
    frame_bytes = Packet.samples_per_frame() * 2
    padded = pcm <> :binary.copy(<<0>>, rem(frame_bytes - rem(byte_size(pcm), frame_bytes), frame_bytes))
    padded |> pcm_samples() |> Mulaw.encode() |> Packet.stream(Packet.new_ssrc())
  end
  def decode(mulaw), do: for(s <- Mulaw.decode(mulaw), into: <<>>, do: <<s::little-signed-16>>)
  defp pcm_samples(pcm), do: for(<<sample::little-signed-16 <- pcm>>, do: sample)
end
