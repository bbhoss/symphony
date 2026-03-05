defmodule SymphonyElixir.Tracker.Local do
  @moduledoc """
  DETS-backed local tracker for dev mode. Issues are stored on disk and
  managed through the web UI instead of a remote service like Linear.
  """

  use Agent

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @dets_table :symphony_local_tracker
  @dets_dir "priv"
  @dets_file "local_tracker.dets"
  @counter_key :__id_counter__
  @comment_prefix :__comment__

  # --- Lifecycle ---

  def start_link(opts \\ []) do
    Agent.start_link(fn -> init_state(opts) end, name: __MODULE__)
  end

  defp init_state(_opts) do
    path = dets_path() |> String.to_charlist()
    File.mkdir_p!(Path.dirname(to_string(path)))
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: path, type: :set)
    :ok
  end

  def stop do
    Agent.stop(__MODULE__)
  after
    :dets.close(@dets_table)
  end

  # --- Tracker behaviour ---

  @impl true
  def fetch_candidate_issues do
    {:ok, all_issues()}
  end

  @impl true
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    issues =
      all_issues()
      |> Enum.filter(fn %Issue{state: state} ->
        MapSet.member?(normalized, normalize_state(state))
      end)

    {:ok, issues}
  end

  @impl true
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    wanted = MapSet.new(issue_ids)

    issues =
      all_issues()
      |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(wanted, id) end)

    {:ok, issues}
  end

  @impl true
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    comment = %{
      id: generate_id("comment"),
      issue_id: issue_id,
      body: body,
      created_at: DateTime.utc_now()
    }

    :dets.insert(@dets_table, {{@comment_prefix, comment.id}, comment})
    :dets.sync(@dets_table)
    :ok
  end

  @impl true
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    case :dets.lookup(@dets_table, issue_id) do
      [{^issue_id, issue}] ->
        updated = %{issue | state: state_name}
        :dets.insert(@dets_table, {issue_id, updated})
        :dets.sync(@dets_table)
        notify_update()
        :ok

      [] ->
        {:error, :issue_not_found}
    end
  end

  # --- Public API for web UI ---

  @spec create_issue(map()) :: {:ok, Issue.t()}
  def create_issue(attrs) when is_map(attrs) do
    id = generate_id("local")
    counter = next_counter()
    identifier = "DEV-#{counter}"
    now = DateTime.utc_now()

    issue = %Issue{
      id: id,
      identifier: identifier,
      title: Map.get(attrs, "title", "Untitled"),
      description: Map.get(attrs, "description"),
      priority: parse_int(Map.get(attrs, "priority")),
      state: Map.get(attrs, "state", "Todo"),
      branch_name: nil,
      url: nil,
      assignee_id: nil,
      labels: parse_labels(Map.get(attrs, "labels", "")),
      blocked_by: [],
      assigned_to_worker: true,
      created_at: now,
      updated_at: now
    }

    :dets.insert(@dets_table, {issue.id, issue})
    :dets.sync(@dets_table)
    notify_update()
    {:ok, issue}
  end

  @spec delete_issue(String.t()) :: :ok | {:error, :issue_not_found}
  def delete_issue(issue_id) when is_binary(issue_id) do
    case :dets.lookup(@dets_table, issue_id) do
      [{^issue_id, _issue}] ->
        :dets.delete(@dets_table, issue_id)
        :dets.sync(@dets_table)
        notify_update()
        :ok

      [] ->
        {:error, :issue_not_found}
    end
  end

  @spec list_issues() :: [Issue.t()]
  def list_issues do
    all_issues()
  end

  # --- Internal ---

  defp all_issues do
    :dets.foldl(
      fn
        {{@comment_prefix, _}, _comment}, acc -> acc
        {@counter_key, _counter}, acc -> acc
        {_id, %Issue{} = issue}, acc -> [issue | acc]
        _other, acc -> acc
      end,
      [],
      @dets_table
    )
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  defp next_counter do
    current =
      case :dets.lookup(@dets_table, @counter_key) do
        [{@counter_key, n}] -> n
        [] -> 0
      end

    next = current + 1
    :dets.insert(@dets_table, {@counter_key, next})
    next
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_val), do: nil

  defp parse_labels(labels) when is_binary(labels) do
    labels
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_labels(_labels), do: []

  defp dets_path do
    Path.join([@dets_dir, @dets_file])
  end

  defp notify_update do
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "orchestrator:updates", :orchestrator_updated)
  end
end
