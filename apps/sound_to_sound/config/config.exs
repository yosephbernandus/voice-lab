import Config
config :voice_lab, port: 4200, serve: config_env() != :test, policy: [loss: 0.0, reorder: 0.0, delay_milliseconds: 0, seed: 42]
