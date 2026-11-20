defmodule VoiceLab.CallSocket do
  @moduledoc """
  One call peer's signaling socket.

  Connect: admit to the room, fetch ICE servers, send `joined`, then ask the room to go
  live. Afterwards the socket is a validated pipe to the other peer: the room checks and
  forwards `offer`/`answer`/`candidate`, and `ping`/`leave` are answered here. Any
  protocol violation sends an `error` frame and closes with 1008.
  """

  @behaviour WebSock

  alias VoiceLab.{CallIce, CallRoom}

  @frame_limit 65_536

  @impl true
  def init(options) do
    room = Keyword.fetch!(options, :room)
    codec = Keyword.fetch!(options, :codec)

    with {:admit, {:ok, role}} <- {:admit, CallRoom.admit(room, codec, self())},
         {:ice, {:ok, servers, relay?}} <- {:ice, CallIce.servers()} do
      send(self(), :call_activate)
      joined = %{type: "joined", role: role, codec: codec, iceServers: servers, relayConfigured: relay?}
      {:push, frame(joined), %{joined: true}}
    else
      {:admit, {:error, reason}} ->
        turn_away(reason, 1008)

      {:ice, {:error, reason}} ->
        CallRoom.leave(self())
        turn_away(reason, 1011)
    end
  end

  @impl true
  def handle_in({data, [opcode: :text]}, %{joined: true} = state) when byte_size(data) <= @frame_limit do
    case Jason.decode(data) do
      {:ok, %{"type" => "leave"}} ->
        CallRoom.leave(self())
        {:stop, :normal, state}

      {:ok, %{"type" => "ping"} = message} when map_size(message) == 1 ->
        {:push, frame(%{type: "pong"}), state}

      {:ok, message} ->
        case CallRoom.relay(self(), message) do
          :ok -> {:ok, state}
          {:error, reason} -> violation(reason, state)
        end

      {:error, _} ->
        violation("invalid signaling message", state)
    end
  end

  # Also what a socket refused at admission says to any text it still manages to send.
  def handle_in({_data, [opcode: :text]}, state), do: violation("message exceeds #{@frame_limit} bytes", state)
  def handle_in({_data, [opcode: :binary]}, state), do: violation("binary signaling is not supported", state)
  def handle_in(_other, state), do: violation("invalid signaling frame", state)

  @impl true
  def handle_info(:call_activate, state) do
    CallRoom.ready(self())
    {:ok, state}
  end

  def handle_info({:call_abort, code}, state), do: {:stop, :normal, {code, "signaling admission failed"}, state}
  def handle_info(:call_ready, state), do: {:push, frame(%{type: "ready"}), state}
  def handle_info({:call_signal, message}, state), do: {:push, frame(message), state}
  def handle_info(:call_peer_left, state), do: {:push, frame(%{type: "peer-left"}), state}
  def handle_info(_ignored, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state) do
    CallRoom.leave(self())
    :ok
  end

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  # The close is deferred to a self-message so the error frame goes out first.
  defp turn_away(reason, code) do
    send(self(), {:call_abort, code})
    {:push, frame(%{type: "error", message: reason}), %{joined: false}}
  end

  defp violation(reason, state),
    do: {:stop, :normal, 1008, [frame(%{type: "error", message: reason})], state}
end
