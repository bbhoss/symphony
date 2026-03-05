import Config

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :symphony_elixir, linear_req_options: [plug: {Req.Test, SymphonyElixir.Linear.Client}]

config :logger, level: :warning
