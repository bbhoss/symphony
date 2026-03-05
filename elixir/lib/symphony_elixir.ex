defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    configure_endpoint()

    children =
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore
      ] ++
        maybe_local_tracker() ++
        [
          SymphonyElixir.Orchestrator,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixir.StatusDashboard
        ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  defp maybe_local_tracker do
    case SymphonyElixir.Config.tracker_kind() do
      "local" -> [SymphonyElixir.Tracker.Local]
      _ -> []
    end
  end

  defp configure_endpoint do
    case SymphonyElixir.Config.server_port() do
      port when is_integer(port) and port > 0 ->
        host = SymphonyElixir.Config.server_host() || "127.0.0.1"

        update_endpoint_config(
          http: [ip: parse_ip(host), port: port],
          url: [host: display_host(host), port: port, scheme: "http"],
          server: true
        )

      _ ->
        :ok
    end
  end

  defp update_endpoint_config(overrides) do
    existing = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(existing, overrides))
  end

  defp display_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"
  defp display_host(host), do: host

  defp parse_ip(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp parse_ip(_host), do: {127, 0, 0, 1}

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
