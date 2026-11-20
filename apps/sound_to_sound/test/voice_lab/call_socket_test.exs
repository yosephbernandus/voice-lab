defmodule VoiceLab.CallSocketTest do
  # Drives the WebSock callbacks from the test process, which stands in for the connection.
  use ExUnit.Case, async: false

  import VoiceLab.TestSupport

  alias VoiceLab.{CallRoom, CallSocket}

  @room "room-0002"

  setup do
    reset_rooms()
    saved = Map.new(["TURN_KEY_ID", "TURN_API_TOKEN"], &{&1, System.get_env(&1)})
    Enum.each(Map.keys(saved), &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- saved, do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  defp decode({:text, json}), do: Jason.decode!(json)
  defp text(map), do: {:text, Jason.encode!(map)}

  defp join(codec \\ "pcmu"), do: CallSocket.init(room: @room, codec: codec)

  test "admission sends joined with role, codec and ICE servers, then asks the room to go live" do
    {:push, frame, %{joined: true}} = join("opus")

    assert %{"type" => "joined", "role" => "offerer", "codec" => "opus", "relayConfigured" => false, "iceServers" => [%{"urls" => [_ | _]}]} =
             decode(frame)

    assert_receive :call_activate
  end

  test "refused admission sends an error frame, then closes with 1008" do
    {:push, frame, state} = CallSocket.init(room: "short", codec: "pcmu")
    assert decode(frame) == %{"type" => "error", "message" => "invalid room"}
    assert_receive {:call_abort, code}
    assert {:stop, :normal, {1008, "signaling admission failed"}, ^state} = CallSocket.handle_info({:call_abort, code}, state)
  end

  test "an ICE failure sends an error frame, closes with 1011 and frees the seat" do
    System.put_env("TURN_KEY_ID", "key")

    {:push, frame, %{joined: false} = state} = join()
    assert decode(frame) == %{"type" => "error", "message" => "TURN configuration is incomplete or invalid"}
    assert_receive {:call_abort, 1011}
    refute_received :call_activate
    assert {:stop, :normal, {1011, "signaling admission failed"}, ^state} = CallSocket.handle_info({:call_abort, 1011}, state)

    assert CallRoom.admit(@room, "opus", peer()) == {:ok, "offerer"}
  end

  test "text on a refused socket is answered with an error and a close" do
    {:push, _, state} = CallSocket.init(room: "short", codec: "pcmu")
    assert {:stop, :normal, 1008, [frame], _} = CallSocket.handle_in({~s({"type":"ping"}), [opcode: :text]}, state)
    assert decode(frame)["type"] == "error"
  end

  test "joining a room that has an offerer gives the answerer role, unless the codec differs" do
    {:ok, "offerer"} = CallRoom.admit(@room, "pcmu", peer())

    {:push, frame, %{joined: false}} = join("opus")
    assert decode(frame) == %{"type" => "error", "message" => "codec mismatch"}

    {:push, frame, %{joined: true}} = join("pcmu")
    assert %{"role" => "answerer"} = decode(frame)
  end

  describe "after joining" do
    setup do
      {:push, _, state} = join()
      %{state: state}
    end

    test "ping gets pong, but only a bare ping", %{state: state} do
      assert {:push, {:text, ~s({"type":"pong"})}, ^state} = CallSocket.handle_in({~s({"type":"ping"}), [opcode: :text]}, state)
      assert {:stop, :normal, 1008, _, _} = CallSocket.handle_in({~s({"type":"ping","x":1}), [opcode: :text]}, state)
    end

    test "leave frees the room slot and stops quietly", %{state: state} do
      assert {:stop, :normal, ^state} = CallSocket.handle_in({~s({"type":"leave"}), [opcode: :text]}, state)
      assert CallRoom.admit(@room, "opus", peer()) == {:ok, "offerer"}
    end

    test "signaling before the room is live is rejected as not ready", %{state: state} do
      frame = ~s({"type":"offer","sdp":"v=0"})
      assert {:stop, :normal, 1008, [error], _} = CallSocket.handle_in({frame, [opcode: :text]}, state)
      assert decode(error) == %{"type" => "error", "message" => "not ready"}
    end

    test "frame-level violations", %{state: state} do
      for {frame, message} <- [
            {{"{not json", [opcode: :text]}, "invalid signaling message"},
            {{String.duplicate("x", 65_537), [opcode: :text]}, "message exceeds 65536 bytes"},
            {{<<1, 2>>, [opcode: :binary]}, "binary signaling is not supported"},
            {{"", [opcode: :ping]}, "invalid signaling frame"}
          ] do
        assert {:stop, :normal, 1008, [error], _} = CallSocket.handle_in(frame, state)
        assert decode(error) == %{"type" => "error", "message" => message}
      end
    end

    test "room notices become the matching frames, unknown messages are ignored", %{state: state} do
      assert {:push, text(%{type: "ready"}), state} == CallSocket.handle_info(:call_ready, state)
      assert {:push, text(%{type: "peer-left"}), state} == CallSocket.handle_info(:call_peer_left, state)

      signal = %{"type" => "answer", "sdp" => "v=0"}
      assert {:push, text(signal), state} == CallSocket.handle_info({:call_signal, signal}, state)
      assert {:ok, state} == CallSocket.handle_info(:whatever, state)
    end

    test "terminate leaves the room", %{state: state} do
      CallSocket.terminate(:normal, state)
      assert CallRoom.admit(@room, "opus", peer()) == {:ok, "offerer"}
    end
  end
end
