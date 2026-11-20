defmodule BeamConformance do
  alias VoiceLab.{Concealment, Fixture, Impairment, Packet, Pipeline}

  def run(%{"cases" => cases}), do: Enum.map(cases, &run_case/1)

  defp run_case(case_data) do
    pcm = Base.decode16!(case_data["pcm_hex"], case: :lower)
    policy = Impairment.policy(loss: case_data["loss"], reorder: case_data["reorder"], delay_milliseconds: case_data["delay_milliseconds"], latency_milliseconds: case_data["latency_milliseconds"], seed: case_data["seed"])
    fixture = %Fixture{path: case_data["fixture"], sample_rate: 8_000, pcm: pcm}
    packets = encode_packets(pcm)
    decisions = Impairment.apply(packets, policy)
    delivered = Impairment.deliver(packets, policy)
    result = Pipeline.run(fixture, policy, strategy(case_data["strategy"]))
    %{"id" => case_data["id"], "decisions" => Enum.map(decisions, &decision_json/1), "delivered" => Enum.map(delivered, &packet_json/1), "pipeline" => %{"statistics" => normalize(result.statistics), "rendered_pcm_hex" => Base.encode16(result.rendered_pcm, case: :lower)}, "strategies" => Enum.into([:silence, :repeat, :fade], %{}, fn name -> rendered = Pipeline.run(fixture, policy, name); {Atom.to_string(name), %{"statistics" => normalize(rendered.statistics), "rendered_pcm_hex" => Base.encode16(rendered.rendered_pcm, case: :lower)}} end)}
  end

  defp encode_packets(pcm) do
    pcm |> pad_to_frame() |> pcm_samples() |> VoiceLab.Mulaw.encode() |> Packet.stream(1_234_567, 65_530)
  end
  defp pad_to_frame(pcm) do
    frame_bytes = Packet.samples_per_frame() * 2
    pcm <> :binary.copy(<<0>>, rem(frame_bytes - rem(byte_size(pcm), frame_bytes), frame_bytes))
  end
  defp pcm_samples(pcm), do: for(<<sample::little-signed-16 <- pcm>>, do: sample)
  defp strategy("silence"), do: :silence
  defp strategy("repeat"), do: :repeat
  defp strategy("fade"), do: :fade
  defp decision_json({kind, packet}) when kind in [:deliver, :drop], do: %{"kind" => Atom.to_string(kind), "packet" => packet_json(packet)}
  defp decision_json({:deliver_after, packet, offset}), do: %{"kind" => "deliver_after", "offset" => offset, "packet" => packet_json(packet)}
  defp packet_json(packet), do: %{"sequence_number" => packet.sequence_number, "timestamp" => packet.timestamp, "ssrc" => packet.ssrc, "payload_hex" => Base.encode16(packet.payload, case: :lower)}
  defp normalize(value) when is_map(value), do: Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value
end
input = IO.read(:stdio, :eof) |> Jason.decode!()
IO.puts(Jason.encode!(BeamConformance.run(input)))
