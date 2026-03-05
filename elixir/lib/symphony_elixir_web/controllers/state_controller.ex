defmodule SymphonyElixirWeb.StateController do
  use SymphonyElixirWeb, :controller

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.StateJSON

  def index(conn, _params) do
    payload = StateJSON.state_payload()
    json(conn, payload)
  end

  def refresh(conn, _params) do
    case Orchestrator.request_refresh() do
      :unavailable ->
        conn
        |> put_status(503)
        |> json(%{error: %{code: "orchestrator_unavailable", message: "Orchestrator is unavailable"}})

      payload ->
        conn
        |> put_status(202)
        |> json(Map.update!(payload, :requested_at, &DateTime.to_iso8601/1))
    end
  end

  def show(conn, %{"issue_identifier" => issue_identifier}) do
    case StateJSON.issue_payload(issue_identifier) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "issue_not_found", message: "Issue not found"}})
    end
  end
end
