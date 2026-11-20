defmodule VoiceLab.Room do
  @moduledoc """
  The single two-seat loopback room behind `/socket`.

  Packets are relayed already parsed: the receiving socket impairs them (ADR-0030), and
  re-parsing bytes this server just packed would be wasted work. A lone socket hears itself.
  """

  use GenServer

  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def join(socket), do: GenServer.call(__MODULE__, {:join, socket})
  def leave(socket), do: GenServer.call(__MODULE__, {:leave, socket})
  def relay(sender, packet), do: GenServer.cast(__MODULE__, {:relay, sender, packet})

  @impl true
  def init(seats), do: {:ok, seats}

  @impl true
  def handle_call({:join, socket}, _from, seats) do
    cond do
      is_map_key(seats, socket) -> {:reply, :ok, seats}
      map_size(seats) >= 2 -> {:reply, {:error, :room_full}, seats}
      true -> {:reply, :ok, Map.put(seats, socket, Process.monitor(socket))}
    end
  end

  def handle_call({:leave, socket}, _from, seats), do: {:reply, :ok, vacate(seats, socket)}

  @impl true
  def handle_cast({:relay, sender, packet}, seats) do
    audience =
      case Map.keys(seats) -- [sender] do
        [] -> [sender]
        others -> others
      end

    for listener <- audience, do: send(listener, {:relay, sender, packet})
    {:noreply, seats}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, socket, _reason}, seats) do
    if seats[socket] == monitor, do: {:noreply, Map.delete(seats, socket)}, else: {:noreply, seats}
  end

  defp vacate(seats, socket) do
    case Map.pop(seats, socket) do
      {nil, _} ->
        seats

      {monitor, rest} ->
        Process.demonitor(monitor, [:flush])
        rest
    end
  end
end
