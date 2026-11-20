defmodule VoiceLab.Concealment do
  alias VoiceLab.Mulaw
  def strategies, do: [:silence, :repeat, :fade]
  def render(outcomes, strategy \\ :silence) do
    {frames, _previous, count} =
      Enum.reduce(outcomes, {[], nil, 0}, fn
        {:play, packet}, {frames, _previous, count} ->
          {[packet.payload | frames], packet.payload, count}

        {:conceal, _}, {frames, previous, count} ->
          frame = concealed(strategy, previous)
          {[frame | frames], previous, count + 1}

        :starved, accumulator ->
          accumulator
      end)

    {frames |> Enum.reverse() |> IO.iodata_to_binary(), count}
  end
  defp concealed(_strategy, nil), do: Mulaw.silence(160)
  defp concealed(:silence, _previous), do: Mulaw.silence(160)
  defp concealed(:repeat, previous), do: previous
  defp concealed(:fade, previous), do: Mulaw.scale(previous, 0.5)
  defp concealed(_, _previous), do: Mulaw.silence(160)
end
