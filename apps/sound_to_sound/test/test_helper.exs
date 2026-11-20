ExUnit.start()

defmodule VoiceLab.TestSupport do
  @moduledoc false

  # A stand-in socket process: everything it receives is forwarded to the test as {:at, pid, message}.
  def peer do
    test = self()
    spawn_link(fn -> forward(test) end)
  end

  defp forward(test) do
    receive do
      message ->
        send(test, {:at, self(), message})
        forward(test)
    end
  end

  # Both rooms are singletons under the app supervisor; restart them for a clean slate.
  def reset_rooms do
    for child <- [VoiceLab.Room, VoiceLab.CallRoom] do
      :ok = Supervisor.terminate_child(VoiceLab.Supervisor, child)
      {:ok, _pid} = Supervisor.restart_child(VoiceLab.Supervisor, child)
    end
  end

  def eventually(check, tries \\ 30) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, tries - 1)
    end
  end
end
