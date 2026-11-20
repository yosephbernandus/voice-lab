defmodule Mix.Tasks.Bench do
  use Mix.Task
  alias VoiceLab.{Concealment, Fixture, Impairment, Wav}
  @requirements ["app.config"]
  @switches [input: :string, output: :string, loss: :float, reorder: :float, delay: :integer, seed: :integer]
  def run(arguments) do
    {options, remaining, invalid} = OptionParser.parse(arguments, strict: @switches)
    if remaining != [] or invalid != [], do: Mix.raise("unknown bench arguments")
    input = Keyword.get(options, :input) || Mix.raise("--input PATH is required")
    output = Keyword.get(options, :output, "bench_out")
    policy = policy(options)
    fixture = case Fixture.load(input) do {:ok, f} -> f; {:error, reason} -> Mix.raise("cannot load fixture: #{inspect(reason)}") end
    File.mkdir_p!(output)
    runs = Enum.map(Concealment.strategies(), fn strategy ->
      result = VoiceLab.Pipeline.run(fixture, policy, strategy)
      filename = "#{strategy}.wav"
      :ok = Wav.write(Path.join(output, filename), result.rendered_pcm, fixture.sample_rate)
      %{strategy: strategy, output: filename, statistics: result.statistics}
    end)
    report = %{fixture: Path.expand(input), sample_rate: fixture.sample_rate, samples_per_packet: VoiceLab.Packet.samples_per_frame(), packet_duration_milliseconds: 20, policy: Map.from_struct(policy), runs: runs}
    File.write!(Path.join(output, "results.json"), Jason.encode_to_iodata!(report, pretty: true))
    Mix.shell().info("wrote #{output}/results.json and #{length(runs)} rendered WAV files")
  end
  defp policy(options) do
    loss = Keyword.get(options, :loss, 0.05); reorder = Keyword.get(options, :reorder, 0.0)
    unless loss >= 0.0 and loss <= 1.0 and reorder >= 0.0 and reorder <= 1.0 and loss + reorder <= 1.0, do: Mix.raise("--loss and --reorder must be fractions whose sum is at most 1")
    Impairment.policy(loss: loss, reorder: reorder, delay_milliseconds: Keyword.get(options, :delay, 0), seed: Keyword.get(options, :seed, 42))
  end
end
