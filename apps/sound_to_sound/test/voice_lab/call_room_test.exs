defmodule VoiceLab.CallRoomTest do
  use ExUnit.Case, async: false

  import VoiceLab.TestSupport

  alias VoiceLab.CallRoom

  @room "room-0001"
  @candidate %{
    "type" => "candidate",
    "candidate" => %{"candidate" => "candidate:1 1 udp 1 10.0.0.1 9 typ host", "sdpMid" => "0", "sdpMLineIndex" => 0}
  }
  @invalid {:error, "invalid signaling message"}

  setup do
    reset_rooms()
  end

  # Two peers admitted and live, as after both sockets completed their handshake.
  defp live_pair(codec \\ "opus") do
    [offerer, answerer] = [peer(), peer()]
    assert {:ok, "offerer"} = CallRoom.admit(@room, codec, offerer)
    assert {:ok, "answerer"} = CallRoom.admit(@room, codec, answerer)
    assert CallRoom.ready(offerer) == :waiting
    assert CallRoom.ready(answerer) == :ok
    assert_receive {:at, ^offerer, :call_ready}
    assert_receive {:at, ^answerer, :call_ready}
    {offerer, answerer}
  end

  defp candidate(line, mid, index),
    do: %{"type" => "candidate", "candidate" => %{"candidate" => line, "sdpMid" => mid, "sdpMLineIndex" => index}}

  describe "admission" do
    test "first peer offers, second answers, third is refused" do
      [a, b, c] = [peer(), peer(), peer()]
      assert CallRoom.admit(@room, "pcmu", a) == {:ok, "offerer"}
      assert CallRoom.admit(@room, "pcmu", b) == {:ok, "answerer"}
      assert CallRoom.admit(@room, "pcmu", c) == {:error, "room is full"}
    end

    test "the second peer must use the first peer's codec" do
      [a, b] = [peer(), peer()]
      {:ok, _} = CallRoom.admit(@room, "pcmu", a)
      assert CallRoom.admit(@room, "opus", b) == {:error, "codec mismatch"}
      assert CallRoom.admit(@room, "pcmu", b) == {:ok, "answerer"}
    end

    test "room ids must be 8 to 48 characters of letters, digits, dash, underscore" do
      for {room, valid?} <- [
            {"1234567", false},
            {"12345678", true},
            {String.duplicate("a", 48), true},
            {String.duplicate("a", 49), false},
            {"has space", false},
            {"slash/room", false},
            {"Mixed_Case-9", true},
            {nil, false}
          ] do
        assert CallRoom.valid_room?(room) == valid?, inspect(room)
        expected = if valid?, do: {:ok, "offerer"}, else: {:error, "invalid room"}
        assert CallRoom.admit(room, "pcmu", peer()) == expected
      end
    end

    test "only pcmu and opus are accepted" do
      assert CallRoom.admit(@room, "g722", peer()) == {:error, "invalid codec"}
      assert CallRoom.admit(@room, nil, peer()) == {:error, "invalid codec"}
    end

    test "a socket cannot be admitted twice, even to another room" do
      a = peer()
      {:ok, _} = CallRoom.admit(@room, "pcmu", a)
      assert CallRoom.admit(@room, "pcmu", a) == {:error, "already joined"}
      assert CallRoom.admit("other-room", "pcmu", a) == {:error, "already joined"}
    end

    test "the server stops opening rooms at 1000 but still seats second peers" do
      for n <- 1..1_000, do: {:ok, _} = CallRoom.admit("room-#{n}-xyz", "pcmu", peer())
      assert CallRoom.admit("room-new-xyz", "pcmu", peer()) == {:error, "server is full"}
      assert {:ok, "answerer"} = CallRoom.admit("room-1-xyz", "pcmu", peer())
    end
  end

  describe "readiness" do
    test "an unknown socket is not ready" do
      assert CallRoom.ready(peer()) == :error
    end

    test "a lone peer keeps waiting, and ready is idempotent once live" do
      a = peer()
      {:ok, _} = CallRoom.admit(@room, "pcmu", a)
      assert CallRoom.ready(a) == :waiting
      refute_receive {:at, ^a, :call_ready}, 30
      CallRoom.leave(a)

      {offerer, answerer} = live_pair()
      assert CallRoom.ready(offerer) == :ok
      assert CallRoom.ready(answerer) == :ok
      refute_receive {:at, _, :call_ready}, 30
    end

    test "nothing is relayed before both peers are live" do
      [a, b] = [peer(), peer()]
      {:ok, _} = CallRoom.admit(@room, "opus", a)
      assert CallRoom.relay(a, @candidate) == {:error, "not ready"}
      {:ok, _} = CallRoom.admit(@room, "opus", b)
      CallRoom.ready(a)
      assert CallRoom.relay(a, @candidate) == {:error, "not ready"}
      assert CallRoom.relay(b, @candidate) == {:error, "not ready"}
      assert CallRoom.relay(peer(), @candidate) == {:error, "not ready"}
    end
  end

  describe "signaling roles" do
    test "offer comes from the offerer, answer from the answerer, each reaches the other" do
      {offerer, answerer} = live_pair()
      offer = %{"type" => "offer", "sdp" => "v=0"}
      answer = %{"type" => "answer", "sdp" => "v=0"}

      assert CallRoom.relay(offerer, offer) == :ok
      assert_receive {:at, ^answerer, {:call_signal, ^offer}}
      assert CallRoom.relay(answerer, answer) == :ok
      assert_receive {:at, ^offerer, {:call_signal, ^answer}}

      assert CallRoom.relay(answerer, offer) == @invalid
      assert CallRoom.relay(offerer, answer) == @invalid
      refute_receive {:at, _, {:call_signal, _}}, 30
    end

    test "sdp must be a string of 1 to 60000 bytes" do
      {offerer, _} = live_pair()
      assert :ok = CallRoom.relay(offerer, %{"type" => "offer", "sdp" => "x"})
      assert :ok = CallRoom.relay(offerer, %{"type" => "offer", "sdp" => String.duplicate("x", 60_000)})

      for sdp <- ["", String.duplicate("x", 60_001), 5, nil] do
        assert CallRoom.relay(offerer, %{"type" => "offer", "sdp" => sdp}) == @invalid
      end
    end

    test "unknown types and non-maps are invalid" do
      {offerer, _} = live_pair()

      for message <- [%{"type" => "bye"}, %{"sdp" => "x"}, %{"type" => "offer"}, [1], "offer", 7] do
        assert CallRoom.relay(offerer, message) == @invalid
      end
    end
  end

  describe "candidate validation" do
    test "either role may send a well-formed candidate, relayed unchanged" do
      {offerer, answerer} = live_pair()
      assert CallRoom.relay(answerer, @candidate) == :ok
      assert_receive {:at, ^offerer, {:call_signal, @candidate}}
      assert CallRoom.relay(offerer, @candidate) == :ok
      assert_receive {:at, ^answerer, {:call_signal, @candidate}}
    end

    test "field bounds" do
      {offerer, answerer} = live_pair()
      long = String.duplicate("c", 4096)

      for good <- [candidate("c", "", 0), candidate(long, String.duplicate("m", 128), 255)] do
        assert CallRoom.relay(answerer, good) == :ok
        assert_receive {:at, ^offerer, {:call_signal, ^good}}
      end

      for bad <- [
            candidate("", "0", 0),
            candidate(long <> "c", "0", 0),
            candidate("c", String.duplicate("m", 129), 0),
            candidate("c", "0", -1),
            candidate("c", "0", 256),
            candidate("c", "0", 1.0),
            candidate("c", nil, 0),
            candidate(nil, "0", 0),
            %{"type" => "candidate", "candidate" => %{"candidate" => "c"}},
            %{"type" => "candidate", "candidate" => "c"},
            %{"type" => "candidate"}
          ] do
        assert CallRoom.relay(answerer, bad) == @invalid, inspect(bad)
      end
    end
  end

  describe "cleanup" do
    test "leave tells the other peer and frees the room for new callers" do
      {offerer, answerer} = live_pair()
      assert CallRoom.leave(offerer) == :ok
      assert_receive {:at, ^answerer, :call_peer_left}
      refute_receive {:at, ^offerer, :call_peer_left}, 30

      assert CallRoom.relay(answerer, @candidate) == {:error, "not ready"}
      assert CallRoom.ready(answerer) == :error
      assert CallRoom.admit(@room, "pcmu", answerer) == {:ok, "offerer"}
      assert CallRoom.admit(@room, "pcmu", offerer) == {:ok, "answerer"}
    end

    test "leaving twice or without joining is harmless" do
      a = peer()
      assert CallRoom.leave(a) == :ok
      {:ok, _} = CallRoom.admit(@room, "pcmu", a)
      assert CallRoom.leave(a) == :ok
      assert CallRoom.leave(a) == :ok
    end

    test "a crashed peer is reported to the survivor and the room is dissolved" do
      {offerer, answerer} = live_pair()
      Process.unlink(offerer)
      Process.exit(offerer, :kill)
      assert_receive {:at, ^answerer, :call_peer_left}
      assert eventually(fn -> CallRoom.ready(answerer) == :error end)
    end

    test "a lone peer leaving frees the room with no notices" do
      a = peer()
      {:ok, _} = CallRoom.admit(@room, "pcmu", a)
      CallRoom.leave(a)
      assert CallRoom.admit(@room, "opus", peer()) == {:ok, "offerer"}
    end
  end
end
