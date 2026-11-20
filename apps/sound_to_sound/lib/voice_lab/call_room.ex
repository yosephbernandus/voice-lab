defmodule VoiceLab.CallRoom do
  @moduledoc """
  Rendezvous for two-peer calls, keyed by room id.

  A room holds at most two seats, first arrival offers and second answers. Each seat
  walks `:joined -> :activated -> :live`; both seats go live in the same step, once both
  sockets have reported activation, and only live seats may relay signaling. When either
  seat goes away (leave or crash) the whole room is dissolved and the survivor is told.
  """

  use GenServer

  @room_limit 1_000
  @codecs ["pcmu", "opus"]
  @sdp_sender %{"offer" => "offerer", "answer" => "answerer"}

  def start_link(_options),
    do: GenServer.start_link(__MODULE__, %{rooms: %{}, by_pid: %{}}, name: __MODULE__)

  def admit(room, codec, socket), do: GenServer.call(__MODULE__, {:admit, room, codec, socket})
  def ready(socket), do: GenServer.call(__MODULE__, {:ready, socket})
  def relay(socket, message), do: GenServer.call(__MODULE__, {:relay, socket, message})
  def leave(socket), do: GenServer.call(__MODULE__, {:leave, socket})

  def valid_room?(room) do
    is_binary(room) and byte_size(room) in 8..48 and room =~ ~r/\A[A-Za-z0-9_-]+\z/
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:admit, room, codec, pid}, _from, state) do
    with :ok <- check_request(room, codec),
         :ok <- check_not_seated(state, pid),
         {:ok, role} <- pick_role(Map.get(state.rooms, room, []), codec, map_size(state.rooms)) do
      seat = %{pid: pid, codec: codec, role: role, stage: :joined, monitor: Process.monitor(pid)}

      state = %{
        rooms: Map.update(state.rooms, room, [seat], &(&1 ++ [seat])),
        by_pid: Map.put(state.by_pid, pid, room)
      }

      {:reply, {:ok, role}, state}
    else
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  def handle_call({:ready, pid}, _from, state) do
    case locate(state, pid) do
      nil ->
        {:reply, :error, state}

      {_room, _seats, %{stage: :live}} ->
        {:reply, :ok, state}

      {room, seats, _seat} ->
        seats = Enum.map(seats, fn seat -> if seat.pid == pid, do: %{seat | stage: :activated}, else: seat end)

        if length(seats) == 2 and Enum.all?(seats, &(&1.stage == :activated)) do
          for seat <- seats, do: send(seat.pid, :call_ready)
          {:reply, :ok, put_room(state, room, Enum.map(seats, &%{&1 | stage: :live}))}
        else
          {:reply, :waiting, put_room(state, room, seats)}
        end
    end
  end

  def handle_call({:relay, pid, message}, _from, state) do
    with {_room, seats, %{stage: :live, role: role}} <- locate(state, pid),
         true <- acceptable?(message, role) do
      for seat <- seats, seat.pid != pid, do: send(seat.pid, {:call_signal, message})
      {:reply, :ok, state}
    else
      false -> {:reply, {:error, "invalid signaling message"}, state}
      _ -> {:reply, {:error, "not ready"}, state}
    end
  end

  def handle_call({:leave, pid}, _from, state), do: {:reply, :ok, dissolve(state, pid)}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case locate(state, pid) do
      {_room, _seats, %{monitor: ^monitor}} -> {:noreply, dissolve(state, pid)}
      _ -> {:noreply, state}
    end
  end

  defp check_request(room, codec) do
    cond do
      not valid_room?(room) -> {:error, "invalid room"}
      codec not in @codecs -> {:error, "invalid codec"}
      true -> :ok
    end
  end

  defp check_not_seated(state, pid),
    do: if(is_map_key(state.by_pid, pid), do: {:error, "already joined"}, else: :ok)

  defp pick_role([_, _], _codec, _open_rooms), do: {:error, "room is full"}
  defp pick_role([%{codec: codec}], codec, _open_rooms), do: {:ok, "answerer"}
  defp pick_role([_], _codec, _open_rooms), do: {:error, "codec mismatch"}
  defp pick_role([], _codec, open_rooms) when open_rooms >= @room_limit, do: {:error, "server is full"}
  defp pick_role([], _codec, _open_rooms), do: {:ok, "offerer"}

  defp locate(state, pid) do
    with {:ok, room} <- Map.fetch(state.by_pid, pid) do
      seats = Map.fetch!(state.rooms, room)
      {room, seats, Enum.find(seats, &(&1.pid == pid))}
    else
      :error -> nil
    end
  end

  defp put_room(state, room, seats), do: %{state | rooms: Map.put(state.rooms, room, seats)}

  defp dissolve(state, pid) do
    case Map.fetch(state.by_pid, pid) do
      :error ->
        state

      {:ok, room} ->
        {seats, rooms} = Map.pop!(state.rooms, room)

        for seat <- seats do
          Process.demonitor(seat.monitor, [:flush])
          if seat.pid != pid, do: send(seat.pid, :call_peer_left)
        end

        %{rooms: rooms, by_pid: Map.drop(state.by_pid, Enum.map(seats, & &1.pid))}
    end
  end

  defp acceptable?(%{"type" => type, "sdp" => sdp}, role)
       when type in ["offer", "answer"] and is_binary(sdp),
       do: @sdp_sender[type] == role and byte_size(sdp) in 1..60_000

  defp acceptable?(
         %{
           "type" => "candidate",
           "candidate" => %{"candidate" => line, "sdpMid" => mid, "sdpMLineIndex" => index}
         },
         _role
       )
       when is_binary(line) and byte_size(line) in 1..4096 and is_binary(mid) and
              byte_size(mid) <= 128 and is_integer(index) and index in 0..255,
       do: true

  defp acceptable?(_message, _role), do: false
end
