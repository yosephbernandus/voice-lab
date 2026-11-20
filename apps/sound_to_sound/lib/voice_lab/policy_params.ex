defmodule VoiceLab.PolicyParams do
  @moduledoc """
  Query-string policy (`loss=0.1&reorder=0&latency=80&delay=60&seed=42`) to `Impairment.Policy`.

  The WebSocket upgrade and the mid-call text frame both route here, so the demo can only
  ever run on one set of bounds. A missing key takes the configured default; a present
  key must parse completely and sit inside its range. The first offender names the error.
  """

  alias VoiceLab.Impairment

  def parse(params) do
    defaults = Application.fetch_env!(:voice_lab, :policy)

    chances = [
      {"loss", defaults[:loss], 0.0, 1.0},
      {"reorder", defaults[:reorder], 0.0, 1.0}
    ]

    counts = [
      {"latency", Keyword.get(defaults, :latency_milliseconds, 0), 0, 1_000},
      {"delay", defaults[:delay_milliseconds], 0, 1_000},
      {"seed", defaults[:seed], 0, 2_147_483_647}
    ]

    with {:ok, [loss, reorder]} <- read(params, chances, &Float.parse/1),
         :ok <- chances_fit(loss, reorder),
         {:ok, [latency, delay, seed]} <- read(params, counts, &Integer.parse/1) do
      {:ok,
       Impairment.policy(
         loss: loss,
         reorder: reorder,
         latency_milliseconds: latency,
         delay_milliseconds: delay,
         seed: seed
       )}
    else
      {:error, name} -> {:error, "invalid " <> name}
    end
  end

  defp read(params, fields, number_parser) do
    Enum.reduce_while(fields, {:ok, []}, fn {name, default, low, high}, {:ok, values} ->
      case within(Map.fetch(params, name), number_parser, low, high) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        :absent -> {:cont, {:ok, values ++ [default]}}
        :error -> {:halt, {:error, name}}
      end
    end)
  end

  defp within(:error, _parser, _low, _high), do: :absent

  defp within({:ok, text}, parser, low, high) do
    case parser.(text) do
      {number, ""} when number >= low and number <= high -> {:ok, number}
      _ -> :error
    end
  end

  defp chances_fit(loss, reorder) when loss + reorder <= 1.0, do: :ok
  defp chances_fit(_loss, _reorder), do: {:error, "loss + reorder"}
end
