defmodule VoiceLab.RoomTest do
  use ExUnit.Case, async: false

  import VoiceLab.TestSupport

  alias VoiceLab.Room

  setup do
    reset_rooms()
  end

  test "two sockets may join, a third is refused" do
    [a, b, c] = [peer(), peer(), peer()]
    assert Room.join(a) == :ok
    assert Room.join(b) == :ok
    assert Room.join(c) == {:error, :room_full}
  end

  test "joining again while seated is harmless" do
    [a, b, c] = [peer(), peer(), peer()]
    assert :ok = Room.join(a)
    assert :ok = Room.join(a)
    assert :ok = Room.join(b)
    assert {:error, :room_full} = Room.join(c)
  end

  test "a packet goes to the other socket only" do
    [a, b] = [peer(), peer()]
    Room.join(a)
    Room.join(b)
    Room.relay(a, :packet)
    assert_receive {:at, ^b, {:relay, ^a, :packet}}
    refute_receive {:at, ^a, _}, 50
  end

  test "a lone socket hears itself" do
    a = peer()
    Room.join(a)
    Room.relay(a, :packet)
    assert_receive {:at, ^a, {:relay, ^a, :packet}}
  end

  test "leaving frees the seat" do
    [a, b, c] = [peer(), peer(), peer()]
    Room.join(a)
    Room.join(b)
    assert Room.leave(a) == :ok
    assert Room.join(c) == :ok
    assert Room.leave(a) == :ok
  end

  test "a socket that dies frees its seat" do
    [a, b, c] = [peer(), peer(), peer()]
    Room.join(a)
    Room.join(b)
    ref = Process.monitor(a)
    Process.unlink(a)
    Process.exit(a, :kill)
    assert_receive {:DOWN, ^ref, :process, ^a, _}
    assert eventually(fn -> Room.join(c) == :ok end)
  end

  test "after one of two leaves, the remaining socket hears itself again" do
    [a, b] = [peer(), peer()]
    Room.join(a)
    Room.join(b)
    Room.leave(b)
    Room.relay(a, :packet)
    assert_receive {:at, ^a, {:relay, ^a, :packet}}
  end
end
