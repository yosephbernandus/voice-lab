defmodule VoiceLab.Socket do
  @moduledoc """
  One loopback peer. The impairment policy shapes what this peer hears (ADR-0030): a
  slider that degraded the other person's audio would show the presenter no change.

  The socket tracks which `{sender, ssrc}` it is currently hearing and a generation
  counter. Every restart of the impairment stream (new source, new policy) bumps the
  generation and announces it as `stream=<generation>&ssrc=<ssrc>` ahead of that
  source's audio. Delayed deliveries carry the generation they were scheduled in and are
  discarded if the stream restarted meanwhile.
  """

  @behaviour WebSock

  alias VoiceLab.{Impairment, Packet, PolicyParams, Room}

  @impl true
  def init(options) do
    case Room.join(self()) do
      :ok ->
        {:ok, %{stream: Impairment.stream(Keyword.fetch!(options, :policy)), heard: nil, generation: 0}}

      {:error, :room_full} ->
        {:stop, :normal, {1013, "room already has two peers"}, %{}}
    end
  end

  @impl true
  def handle_in({frame, [opcode: :binary]}, state) do
    case Packet.parse(frame) do
      {:ok, packet} ->
        Room.relay(self(), packet)
        {:ok, state}

      {:error, reason} ->
        {:stop, :normal, {1008, Atom.to_string(reason)}, state}
    end
  end

  # A slider moved; text frames use the same validator as the upgrade query.
  def handle_in({frame, [opcode: :text]}, state) do
    case PolicyParams.parse(URI.decode_query(frame)) do
      {:ok, policy} ->
        state = restart(state, policy, state.heard)
        push(announce(state), state)

      {:error, reason} ->
        {:stop, :normal, {1008, reason}, state}
    end
  end

  @impl true
  def handle_info({:relay, sender, packet}, state) do
    source = {sender, packet.ssrc}

    {lead, state} =
      if state.heard == source do
        {[], state}
      else
        state = restart(state, state.stream.policy, source)
        {announce(state), state}
      end

    {decision, stream} = Impairment.next(packet, state.stream)
    wait = stream.policy.latency_milliseconds
    push(lead ++ route(decision, wait, state.generation), %{state | stream: stream})
  end

  def handle_info({:deliver, generation, packet}, %{generation: generation} = state),
    do: {:push, {:binary, Packet.pack(packet)}, state}

  def handle_info(_stale_or_unknown, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state) do
    Room.leave(self())
    :ok
  end

  # Fresh impairment stream, next generation, `heard` kept or replaced by the caller.
  defp restart(state, policy, heard),
    do: %{state | stream: Impairment.stream(policy), heard: heard, generation: state.generation + 1}

  defp announce(%{heard: nil}), do: []
  defp announce(%{heard: {_sender, ssrc}, generation: generation}), do: [{:text, "stream=#{generation}&ssrc=#{ssrc}"}]

  defp route({:drop, _packet}, _wait, _generation), do: []
  defp route({:deliver, packet}, 0, _generation), do: [{:binary, Packet.pack(packet)}]
  defp route({:deliver, packet}, wait, generation), do: later(packet, wait, generation)
  defp route({:deliver_after, packet, extra}, wait, generation), do: later(packet, wait + extra, generation)

  defp later(packet, wait, generation) do
    Process.send_after(self(), {:deliver, generation, packet}, wait)
    []
  end

  defp push([], state), do: {:ok, state}
  defp push(frames, state), do: {:push, frames, state}
end
