defmodule VoiceLab.Impairment do
  import Kernel, except: [apply: 2]
  defmodule Policy do
    defstruct loss: 0.0, reorder: 0.0, delay_milliseconds: 0, latency_milliseconds: 0, seed: 42
  end
  defmodule Stream do
    defstruct [:policy, :random_state]
  end
  def policy(opts \\ []), do: struct!(Policy, opts)
  def stream(%Policy{} = p), do: %Stream{policy: p, random_state: :rand.seed_s(:exsss, {p.seed, p.seed, p.seed})}
  def apply(packets, %Policy{} = p), do: Enum.map_reduce(packets, stream(p), fn packet, s -> next(packet, s) end) |> elem(0)
  def next(packet, %Stream{} = s) do
    {roll, state} = :rand.uniform_s(s.random_state)
    decision = cond do
      roll < s.policy.loss -> {:drop, packet}
      roll < s.policy.loss + s.policy.reorder -> {:deliver_after, packet, s.policy.delay_milliseconds}
      true -> {:deliver, packet}
    end
    {decision, %{s | random_state: state}}
  end
  def deliver(packets, policy) do
    packets |> apply(policy) |> Enum.reduce({[], nil}, fn
      {:drop, _}, acc -> acc
      {:deliver, p}, {out, nil} -> {[p | out], nil}
      {:deliver, p}, {out, held} -> {[held, p | out], nil}
      {:deliver_after, p, _}, {out, nil} -> {out, p}
      {:deliver_after, p, _}, {out, held} -> {[held | out], p}
    end) |> then(fn {out, nil} -> Enum.reverse(out); {out, held} -> Enum.reverse([held | out]) end)
  end
end
