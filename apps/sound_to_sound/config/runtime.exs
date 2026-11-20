import Config
if config_env() != :test do
  config :voice_lab, port: String.to_integer(System.get_env("SOUND_TO_SOUND_PORT", "4200"))
end
