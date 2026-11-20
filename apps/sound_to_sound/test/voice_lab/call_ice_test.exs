defmodule VoiceLab.CallIceTest do
  use ExUnit.Case, async: false

  alias VoiceLab.CallIce

  @turn_vars ["TURN_KEY_ID", "TURN_API_TOKEN"]
  @turn %{"urls" => ["stun:s.example:3478", "turn:t.example:3478"], "username" => "u", "credential" => "c"}

  setup do
    saved = Map.new(@turn_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved, do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    Enum.each(@turn_vars, &System.delete_env/1)
  end

  describe "servers/0 configuration" do
    test "no TURN settings gives the public STUN server and no relay" do
      assert {:ok, [%{"urls" => ["stun:" <> _]}], false} = CallIce.servers()
    end

    test "half-configured or malformed TURN settings are refused without a network call" do
      for env <- [
            %{"TURN_KEY_ID" => "abc"},
            %{"TURN_API_TOKEN" => "x"},
            %{"TURN_KEY_ID" => "", "TURN_API_TOKEN" => "x"},
            %{"TURN_KEY_ID" => "abc", "TURN_API_TOKEN" => ""},
            %{"TURN_KEY_ID" => "bad key/../x", "TURN_API_TOKEN" => "x"},
            %{"TURN_KEY_ID" => String.duplicate("k", 129), "TURN_API_TOKEN" => "x"}
          ] do
        Enum.each(env, fn {name, value} -> System.put_env(name, value) end)
        assert CallIce.servers() == {:error, "TURN configuration is incomplete or invalid"}, inspect(env)
        Enum.each(@turn_vars, &System.delete_env/1)
      end
    end
  end

  describe "accept_provider_servers/1" do
    test "a list whose TURN entry has username and password is accepted as is" do
      assert CallIce.accept_provider_servers([@turn]) == {:ok, [@turn]}
    end

    test "a single object is wrapped and a bare url string is allowed" do
      single = %{"urls" => "turns:t.example:443", "username" => "u", "credential" => "c"}
      assert CallIce.accept_provider_servers(single) == {:ok, [single]}
    end

    test "anything that cannot relay or is malformed is rejected" do
      for value <- [
            nil,
            [],
            [%{"urls" => ["stun:s.example"]}],
            [@turn, %{"urls" => ["http://x"]}],
            [@turn, %{"urls" => []}],
            [@turn, %{"urls" => [5]}],
            [@turn, "stun:x"],
            [Map.delete(@turn, "username")],
            [%{@turn | "credential" => ""}],
            [%{@turn | "username" => nil}]
          ] do
        assert CallIce.accept_provider_servers(value) == :error, inspect(value)
      end
    end
  end
end
