defmodule VoiceLab.MixProject do
  use Mix.Project
  def project, do: [app: :voice_lab, version: "0.1.0", elixir: "~> 1.17", start_permanent: Mix.env() == :prod, deps: deps(), elixirc_paths: ["lib"]]
  def application, do: [mod: {VoiceLab.Application, []}, extra_applications: [:logger, :inets, :ssl]]
  defp deps, do: [{:bandit, "~> 1.8"}, {:jason, "~> 1.4"}, {:plug, "~> 1.18"}, {:websock_adapter, "~> 0.6"}]
end
