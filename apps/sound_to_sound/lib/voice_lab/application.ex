defmodule VoiceLab.Application do
  use Application
  def start(_type, _args) do
    children = [{VoiceLab.Room, []}, {VoiceLab.CallRoom, []}] ++ if(Application.get_env(:voice_lab, :serve, true), do: [{Bandit, plug: VoiceLab.Router, scheme: :http, port: Application.get_env(:voice_lab, :port, 4200)}], else: [])
    Supervisor.start_link(children, strategy: :one_for_one, name: VoiceLab.Supervisor)
  end
end
