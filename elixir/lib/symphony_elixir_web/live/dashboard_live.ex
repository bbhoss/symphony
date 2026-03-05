defmodule SymphonyElixirWeb.DashboardLive do
  use SymphonyElixirWeb, :live_view

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.StateJSON

  @topic "orchestrator:updates"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, @topic)
    end

    payload = StateJSON.state_payload()

    {:ok, assign(socket, payload: payload)}
  end

  @impl true
  def handle_info(:orchestrator_updated, socket) do
    payload = StateJSON.state_payload()
    {:noreply, assign(socket, payload: payload)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Orchestrator.request_refresh()
    payload = StateJSON.state_payload()
    {:noreply, assign(socket, payload: payload)}
  end

  defp truncate_session(nil), do: ""

  defp truncate_session(session_id) when is_binary(session_id) and byte_size(session_id) > 12 do
    String.slice(session_id, 0, 12) <> "..."
  end

  defp truncate_session(session_id), do: to_string(session_id)

  defp format_number(nil), do: "0"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)
end
