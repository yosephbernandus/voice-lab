defmodule VoiceLab.SocketTest do
  # Drives the WebSock callbacks from the test process, which stands in for the connection.
  use ExUnit.Case, async: false

  import VoiceLab.TestSupport

  alias VoiceLab.{Impairment, Packet, Room, Socket}

  setup do
    reset_rooms()
  end

  defp packet(ssrc, sequence \\ 0),
    do: %Packet{sequence_number: sequence, timestamp: sequence * 160, ssrc: ssrc, payload: :binary.copy(<<0xFF>>, 160)}

  defp open(policy_options) do
    {:ok, state} = Socket.init(policy: Impairment.policy(policy_options))
    state
  end

  defp hear(state, sender, packet), do: Socket.handle_info({:relay, sender, packet}, state)
  defp tune(state, query), do: Socket.handle_in({query, [opcode: :text]}, state)

  defp wire(packet), do: {:binary, Packet.pack(packet)}

  test "a third socket is closed with 1013" do
    [a, b] = [peer(), peer()]
    Room.join(a)
    Room.join(b)
    assert {:stop, :normal, {1013, "room already has two peers"}, _} = Socket.init(policy: Impairment.policy())
  end

  test "a new source is announced with a generation ahead of its first packet" do
    state = open([])
    sender = peer()
    {:push, frames, state} = hear(state, sender, packet(7))
    assert frames == [{:text, "stream=1&ssrc=7"}, wire(packet(7))]

    assert {:push, [{:binary, _}], state} = hear(state, sender, packet(7, 1))

    {:push, frames, _state} = hear(state, peer(), packet(9))
    assert [{:text, "stream=2&ssrc=9"}, {:binary, _}] = frames
  end

  test "the same ssrc from a different sender is a different source" do
    state = open([])
    {:push, [{:text, "stream=1&ssrc=7"}, _], state} = hear(state, peer(), packet(7))
    assert {:push, [{:text, "stream=2&ssrc=7"}, _], _} = hear(state, peer(), packet(7))
  end

  test "a policy change re-announces the current source under a new generation" do
    state = open([])
    sender = peer()
    {:push, _, state} = hear(state, sender, packet(7))

    assert {:push, [{:text, "stream=2&ssrc=7"}], state} = tune(state, "loss=0")
    assert {:push, [{:binary, _}], _} = hear(state, sender, packet(7, 1))
  end

  test "a policy change before any audio is silent" do
    assert {:ok, _} = tune(open([]), "latency=10")
  end

  test "an invalid policy closes with 1008 and the validator's reason" do
    assert {:stop, :normal, {1008, "invalid loss"}, _} = tune(open([]), "loss=9")
    assert {:stop, :normal, {1008, "invalid loss + reorder"}, _} = tune(open([]), "loss=0.7&reorder=0.7")
  end

  test "malformed binary frames close with 1008 and the parse error" do
    state = open([])
    assert {:stop, :normal, {1008, "short_packet"}, _} = Socket.handle_in({<<0x80, 0>>, [opcode: :binary]}, state)
    assert {:stop, :normal, {1008, "unsupported_version"}, _} = Socket.handle_in({<<0, 0::96>>, [opcode: :binary]}, state)
  end

  test "a valid binary frame is relayed to the room" do
    sender = peer()
    {:ok, state} = Socket.init(policy: Impairment.policy())
    Room.join(sender)
    me = self()
    assert {:ok, ^state} = Socket.handle_in({Packet.pack(packet(3)), [opcode: :binary]}, state)
    assert_receive {:at, ^sender, {:relay, ^me, %Packet{ssrc: 3}}}
  end

  describe "delayed deliveries" do
    test "latency postpones delivery to a later message" do
      state = open(latency_milliseconds: 20)
      {:push, [{:text, "stream=1&ssrc=7"}], state} = hear(state, peer(), packet(7))

      assert_receive delayed, 500
      assert {:push, {:binary, _}, _} = Socket.handle_info(delayed, state)
    end

    test "reordered packets arrive after latency plus delay" do
      state = open(reorder: 1.0, delay_milliseconds: 80, latency_milliseconds: 50)
      {:push, [{:text, _}], _state} = hear(state, peer(), packet(7))

      refute_receive _, 30
      assert_receive {:deliver, _, %Packet{ssrc: 7}}, 500
    end

    test "delivery waits for latency plus delay" do
      state = open(reorder: 1.0, delay_milliseconds: 80, latency_milliseconds: 50)
      started = System.monotonic_time(:millisecond)
      {:push, [{:text, _}], _state} = hear(state, peer(), packet(7))

      refute_receive {:deliver, _, _}, 110
      assert_receive {:deliver, _, %Packet{ssrc: 7}}, 500
      assert System.monotonic_time(:millisecond) - started >= 130 - 5
    end

    test "dropped packets deliver nothing, ever" do
      state = open(loss: 1.0)
      {:push, [{:text, _}], _state} = hear(state, peer(), packet(7))
      refute_receive _, 50
    end

    test "a policy change invalidates deliveries scheduled before it" do
      state = open(latency_milliseconds: 20)
      sender = peer()
      {:push, _, state} = hear(state, sender, packet(7))
      assert_receive stale, 500

      {:push, [{:text, "stream=2&ssrc=7"}], state} = tune(state, "latency=20")
      assert {:ok, ^state} = Socket.handle_info(stale, state)

      {:ok, state} = hear(state, sender, packet(7, 1))
      assert_receive fresh, 500
      assert {:push, {:binary, _}, _} = Socket.handle_info(fresh, state)
    end

    test "a source change invalidates deliveries scheduled for the previous source" do
      state = open(latency_milliseconds: 20)
      {:push, _, state} = hear(state, peer(), packet(7))
      assert_receive stale, 500

      {:push, [{:text, "stream=2&ssrc=9"}], state} = hear(state, peer(), packet(9))
      assert {:ok, ^state} = Socket.handle_info(stale, state)
    end

    test "the same source keeps its generation, so earlier deliveries still land" do
      state = open(latency_milliseconds: 20)
      sender = peer()
      {:push, _, state} = hear(state, sender, packet(7))
      {:ok, state} = hear(state, sender, packet(7, 1))
      assert_receive first, 500
      assert_receive second, 500
      assert {:push, {:binary, _}, _} = Socket.handle_info(first, state)
      assert {:push, {:binary, _}, _} = Socket.handle_info(second, state)
    end
  end

  describe "seeded impairment stream" do
    # Which of `count` packets from one source get through, in order.
    defp survivors(state, sender, ssrc, count) do
      Enum.map_reduce(0..(count - 1), state, fn sequence, state ->
        case hear(state, sender, packet(ssrc, sequence)) do
          {:push, frames, state} -> {Enum.any?(frames, &match?({:binary, _}, &1)), state}
          {:ok, state} -> {false, state}
        end
      end)
    end

    test "a new source and a policy change each restart the stream from its seed" do
      {baseline, _} = survivors(open(loss: 0.5, seed: 7), peer(), 7, 40)
      assert true in baseline and false in baseline

      state = open(loss: 0.5, seed: 7)
      sender = peer()
      {first, state} = survivors(state, sender, 7, 40)
      assert first == baseline

      other = peer()
      {after_new_source, state} = survivors(state, other, 9, 40)
      assert after_new_source == baseline

      {:push, [{:text, _}], state} = tune(state, "loss=0.5&seed=7")
      # Same source as the last packets, so no announcement leads these.
      {after_policy_change, _} = survivors(state, other, 9, 40)
      assert after_policy_change == baseline
    end
  end

  test "the sender is never impaired by its own policy" do
    sender = peer()
    {:ok, state} = Socket.init(policy: Impairment.policy(loss: 1.0))
    Room.join(sender)
    me = self()
    frame = Packet.pack(packet(3))

    assert {:ok, ^state} = Socket.handle_in({frame, [opcode: :binary]}, state)
    assert_receive {:at, ^sender, {:relay, ^me, %Packet{ssrc: 3} = relayed}}
    assert Packet.pack(relayed) == frame

    # What it hears is impaired, and sending changed nothing about that.
    assert {:push, [{:text, _}], _} = hear(state, sender, packet(4))
  end

  test "terminate frees the seat" do
    [a, b] = [peer(), peer()]
    {:ok, state} = Socket.init(policy: Impairment.policy())
    assert Room.join(a) == :ok
    assert Room.join(b) == {:error, :room_full}
    Socket.terminate(:normal, state)
    assert Room.join(b) == :ok
  end
end
