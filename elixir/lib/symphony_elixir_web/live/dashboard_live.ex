defmodule SymphonyElixirWeb.DashboardLive do
  use SymphonyElixirWeb, :live_view

  alias SymphonyElixir.{Config, Orchestrator, Tracker.Local}
  alias SymphonyElixirWeb.StateJSON

  @topic "orchestrator:updates"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, @topic)
    end

    payload = StateJSON.state_payload()
    local? = Config.tracker_kind() == :local
    local_issues = if local?, do: Local.list_issues(), else: []

    {:ok,
     assign(socket,
       payload: payload,
       local_tracker: local?,
       local_issues: local_issues,
       show_create_form: false
     )}
  end

  @impl true
  def handle_info(:orchestrator_updated, socket) do
    payload = StateJSON.state_payload()
    socket = if socket.assigns.local_tracker, do: assign(socket, local_issues: Local.list_issues()), else: socket
    {:noreply, assign(socket, payload: payload)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Orchestrator.request_refresh()
    payload = StateJSON.state_payload()
    {:noreply, assign(socket, payload: payload)}
  end

  def handle_event("toggle_create_form", _params, socket) do
    {:noreply, assign(socket, show_create_form: !socket.assigns.show_create_form)}
  end

  def handle_event("create_issue", %{"issue" => params}, socket) do
    {:ok, _issue} = Local.create_issue(params)
    {:noreply, assign(socket, local_issues: Local.list_issues(), show_create_form: false)}
  end

  def handle_event("delete_issue", %{"id" => id}, socket) do
    Local.delete_issue(id)
    {:noreply, assign(socket, local_issues: Local.list_issues())}
  end

  def handle_event("update_state", %{"id" => id, "state" => state}, socket) do
    Local.update_issue_state(id, state)
    {:noreply, assign(socket, local_issues: Local.list_issues())}
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
