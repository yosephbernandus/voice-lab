defmodule VoiceLab.JitterBuffer do
  alias VoiceLab.Sequence
  defstruct packets: %{}, next_sequence_number: nil, window: 3, statistics: %{received: 0, played: 0, concealed: 0, late: 0, duplicate: 0}
  def new(opts \\ []), do: %__MODULE__{window: Keyword.get(opts, :window, 3), next_sequence_number: Keyword.get(opts, :first_sequence_number)}
  def push(%__MODULE__{next_sequence_number: nil} = b, p), do: %{b | next_sequence_number: p.sequence_number, packets: %{p.sequence_number => p}, statistics: inc(b.statistics, :received)}
  def push(b, p) do
    cond do
      Map.has_key?(b.packets, p.sequence_number) -> %{b | statistics: b.statistics |> inc(:received) |> inc(:duplicate)}
      Sequence.precedes?(p.sequence_number, b.next_sequence_number) -> %{b | statistics: b.statistics |> inc(:received) |> inc(:late)}
      true -> %{b | packets: Map.put(b.packets, p.sequence_number, p), statistics: inc(b.statistics, :received)}
    end
  end
  def pop(b), do: release(b, false)
  def pop(b, :end_of_stream), do: release(b, true)
  def statistics(b), do: b.statistics
  defp release(%__MODULE__{next_sequence_number: nil} = b, _), do: {:starved, b}
  defp release(b, eof) do
    expected = b.next_sequence_number
    case Map.pop(b.packets, expected) do
      {nil, rest} ->
        if eof or beyond?(b, expected) do
          {{:conceal, :lost}, %{b | packets: rest, next_sequence_number: Sequence.next(expected), statistics: inc(b.statistics, :concealed)}}
        else
          {:starved, b}
        end
      {packet, rest} ->
        {{:play, packet}, %{b | packets: rest, next_sequence_number: Sequence.next(expected), statistics: inc(b.statistics, :played)}}
    end
  end
  defp beyond?(b, expected), do: Enum.any?(b.packets, fn {n, _} -> Sequence.distance(expected, n) > b.window end)
  defp inc(map, key), do: Map.update!(map, key, &(&1 + 1))
end
