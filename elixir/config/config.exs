import Config

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: SymphonyElixirWeb.ErrorJSON], layout: false],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony_lv"],
  server: false

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
