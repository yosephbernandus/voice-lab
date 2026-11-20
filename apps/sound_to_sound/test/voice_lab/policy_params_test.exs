defmodule VoiceLab.PolicyParamsTest do
  use ExUnit.Case, async: true

  alias VoiceLab.PolicyParams

  defp parse(query), do: query |> URI.decode_query() |> PolicyParams.parse()

  test "empty input yields the configured defaults" do
    assert {:ok, policy} = parse("")
    assert {policy.loss, policy.reorder, policy.latency_milliseconds, policy.delay_milliseconds, policy.seed} ==
             {0.0, 0.0, 0, 0, 42}
  end

  test "all keys parse together" do
    assert {:ok, policy} = parse("loss=0.1&reorder=0.25&latency=80&delay=60&seed=7")
    assert {policy.loss, policy.reorder, policy.latency_milliseconds, policy.delay_milliseconds, policy.seed} ==
             {0.1, 0.25, 80, 60, 7}
  end

  test "range ends are accepted" do
    assert {:ok, _} = parse("loss=0&reorder=0&latency=0&delay=0&seed=0")
    assert {:ok, _} = parse("loss=1&latency=1000&delay=1000&seed=2147483647")
    assert {:ok, _} = parse("reorder=1")
  end

  test "values just outside a range name the offending key" do
    for {query, key} <- [
          {"loss=1.01", "loss"},
          {"loss=-0.1", "loss"},
          {"reorder=1.5", "reorder"},
          {"latency=1001", "latency"},
          {"latency=-1", "latency"},
          {"delay=1001", "delay"},
          {"seed=2147483648", "seed"},
          {"seed=-1", "seed"}
        ] do
      assert parse(query) == {:error, "invalid " <> key}, query
    end
  end

  test "partial or non-numeric text is rejected" do
    for query <- ["loss=abc", "loss=0.5x", "loss=", "loss=.5", "latency=1.5", "latency=10ms", "seed=0x10", "delay= 5"] do
      assert {:error, "invalid " <> _} = parse(query), query
    end
  end

  test "loss and reorder may not exceed one together" do
    assert {:ok, _} = parse("loss=0.5&reorder=0.5")
    assert parse("loss=0.6&reorder=0.5") == {:error, "invalid loss + reorder"}
  end

  test "the first failing check wins: fractions, then their sum, then integers" do
    assert parse("loss=2&latency=5000") == {:error, "invalid loss"}
    assert parse("loss=0.9&reorder=0.9&latency=5000") == {:error, "invalid loss + reorder"}
    assert parse("latency=5000&seed=-1") == {:error, "invalid latency"}
  end
end
