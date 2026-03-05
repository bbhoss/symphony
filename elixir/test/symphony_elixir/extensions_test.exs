defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)
    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert match?({:ok, _pid}, restart_result) or match?({:error, {:already_started, _pid}}, restart_result)
    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.tracker_kind() == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"
    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}
    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "state json payload building covers running, retrying, and issue payloads with nil fields" do
    alias SymphonyElixirWeb.StateJSON

    snapshot = %{
      running: [
        %{
          issue_id: "issue-both",
          identifier: "MT-BOTH",
          state: "In Progress",
          session_id: "thread-both",
          turn_count: 7,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: nil,
          last_codex_timestamp: nil,
          last_codex_message: %{unexpected: true},
          last_codex_event: :notification
        }
      ],
      retrying: [
        %{
          issue_id: "issue-both",
          identifier: "MT-BOTH",
          attempt: 3,
          due_in_ms: nil,
          error: "still retrying"
        }
      ],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :StaticOrchestrator)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: true, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    # state_payload: counts, running entry shape, retry entry shape
    payload = StateJSON.state_payload(orchestrator_name, 5_000)
    assert %{counts: %{running: 1, retrying: 1}, generated_at: generated_at} = payload
    assert is_binary(generated_at)

    assert [running] = payload.running
    assert running.issue_identifier == "MT-BOTH"
    assert running.turn_count == 7
    assert running.last_message == nil
    assert running.started_at == nil
    assert running.last_event_at == nil
    assert running.tokens == %{input_tokens: 4, output_tokens: 8, total_tokens: 12}

    assert [retrying] = payload.retrying
    assert retrying.issue_identifier == "MT-BOTH"
    assert retrying.attempt == 3
    assert retrying.due_at == nil
    assert retrying.error == "still retrying"

    # issue_payload: both running and retrying exist for same issue → status "running"
    assert {:ok, issue} = StateJSON.issue_payload("MT-BOTH", orchestrator_name, 5_000)
    assert issue.status == "running"
    assert issue.issue_id == "issue-both"
    assert issue.running.turn_count == 7
    assert issue.running.last_message == nil
    assert issue.retry.due_at == nil
    assert issue.retry.attempt == 3
    assert issue.attempts == %{restart_count: 2, current_retry_attempt: 3}
    assert issue.recent_events == []
    assert issue.last_error == "still retrying"

    # issue not found
    assert {:error, :issue_not_found} = StateJSON.issue_payload("MT-MISSING", orchestrator_name, 5_000)
  end

  test "state json handles fully populated entries with timestamps and due_at" do
    alias SymphonyElixirWeb.StateJSON

    now = DateTime.utc_now()

    snapshot = %{
      running: [
        %{
          issue_id: "issue-full",
          identifier: "MT-FULL",
          state: "In Progress",
          session_id: "thread-full",
          turn_count: 5,
          codex_input_tokens: 100,
          codex_output_tokens: 200,
          codex_total_tokens: 300,
          started_at: now,
          last_codex_timestamp: now,
          last_codex_message: %{message: "working on it"},
          last_codex_event: :notification
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 60_000,
          error: "timeout"
        }
      ],
      codex_totals: %{input_tokens: 100, output_tokens: 200, total_tokens: 300, seconds_running: 45},
      rate_limits: %{remaining: 50}
    }

    orchestrator_name = Module.concat(__MODULE__, :FullOrchestrator)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    payload = StateJSON.state_payload(orchestrator_name, 5_000)

    # running entry: timestamps are ISO8601 strings, structured message extracted
    assert [running] = payload.running
    assert is_binary(running.started_at)
    assert running.started_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert is_binary(running.last_event_at)
    assert running.last_message == "working on it"
    assert running.tokens == %{input_tokens: 100, output_tokens: 200, total_tokens: 300}

    # retrying entry: due_at is a future ISO8601 string
    assert [retrying] = payload.retrying
    assert is_binary(retrying.due_at)
    assert retrying.due_at =~ ~r/^\d{4}-\d{2}-\d{2}T/

    # codex totals and rate limits passed through
    assert payload.codex_totals == %{input_tokens: 100, output_tokens: 200, total_tokens: 300, seconds_running: 45}
    assert payload.rate_limits == %{remaining: 50}

    # issue detail: running-only issue has recent_events with timestamp
    assert {:ok, issue} = StateJSON.issue_payload("MT-FULL", orchestrator_name, 5_000)
    assert issue.status == "running"
    assert issue.running.started_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert issue.running.last_message == "working on it"
    assert issue.retry == nil
    assert issue.last_error == nil
    assert length(issue.recent_events) == 1
    assert hd(issue.recent_events).message == "working on it"

    # retrying-only issue
    assert {:ok, retry_issue} = StateJSON.issue_payload("MT-RETRY", orchestrator_name, 5_000)
    assert retry_issue.status == "retrying"
    assert retry_issue.running == nil
    assert retry_issue.retry.attempt == 2
    assert is_binary(retry_issue.retry.due_at)
    assert retry_issue.last_error == "timeout"
    assert retry_issue.recent_events == []
    assert retry_issue.attempts == %{restart_count: 1, current_retry_attempt: 2}
  end

  test "state json handles all summarize_message variants" do
    alias SymphonyElixirWeb.StateJSON

    base_entry = %{
      issue_id: "issue-msg",
      identifier: "MT-MSG",
      state: "In Progress",
      session_id: "thread-msg",
      turn_count: 1,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: nil,
      last_codex_timestamp: nil,
      last_codex_event: :notification
    }

    # Wrapped map with :message key
    entry_wrapped = Map.put(base_entry, :last_codex_message, %{message: "wrapped text"})
    assert %{last_message: "wrapped text"} = StateJSON.running_entry_payload(entry_wrapped)

    # Bare binary string
    entry_string = Map.put(base_entry, :last_codex_message, "plain text")
    assert %{last_message: "plain text"} = StateJSON.running_entry_payload(entry_string)

    # Nil message
    entry_nil = Map.put(base_entry, :last_codex_message, nil)
    assert %{last_message: nil} = StateJSON.running_entry_payload(entry_nil)

    # Non-matching map (no :message key)
    entry_other = Map.put(base_entry, :last_codex_message, %{unexpected: true})
    assert %{last_message: nil} = StateJSON.running_entry_payload(entry_other)

    # Atom (non-binary, non-map)
    entry_atom = Map.put(base_entry, :last_codex_message, :some_atom)
    assert %{last_message: nil} = StateJSON.running_entry_payload(entry_atom)
  end

  test "state json running_entry_payload defaults turn_count to 0 when missing" do
    alias SymphonyElixirWeb.StateJSON

    entry_no_turn = %{
      issue_id: "issue-no-turn",
      identifier: "MT-NO-TURN",
      state: "In Progress",
      session_id: "thread",
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: nil,
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }

    result = StateJSON.running_entry_payload(entry_no_turn)
    assert result.turn_count == 0
  end

  test "state json retry_entry_payload with integer due_in_ms" do
    alias SymphonyElixirWeb.StateJSON

    entry = %{
      issue_id: "issue-retry",
      identifier: "MT-RETRY",
      attempt: 4,
      due_in_ms: 120_000,
      error: "crash"
    }

    result = StateJSON.retry_entry_payload(entry)
    assert result.issue_id == "issue-retry"
    assert result.issue_identifier == "MT-RETRY"
    assert result.attempt == 4
    assert result.error == "crash"
    assert is_binary(result.due_at)
    assert result.due_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
  end

  test "state json handles unavailable and timeout orchestrator" do
    alias SymphonyElixirWeb.StateJSON

    payload = StateJSON.state_payload(:nonexistent_orchestrator, 5_000)
    assert %{error: %{code: "snapshot_unavailable"}} = payload
    assert is_binary(payload.generated_at)

    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, timeout_pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)

    on_exit(fn ->
      if Process.alive?(timeout_pid), do: Process.exit(timeout_pid, :normal)
    end)

    timeout_payload = StateJSON.state_payload(timeout_orchestrator, 1)
    assert %{error: %{code: "snapshot_timeout"}} = timeout_payload
    assert is_binary(timeout_payload.generated_at)

    # issue_payload also returns not_found for unavailable orchestrator
    assert {:error, :issue_not_found} = StateJSON.issue_payload("MT-1", :nonexistent_orchestrator, 5_000)
  end

  test "state json refresh payload converts requested_at to iso8601" do
    orchestrator_name = Module.concat(__MODULE__, :RefreshOrchestrator)
    requested_at = DateTime.utc_now()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: %{running: [], retrying: [], codex_totals: nil, rate_limits: nil},
        refresh: %{queued: true, coalesced: false, requested_at: requested_at, operations: ["poll", "reconcile"]}
      )

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    # Simulate what StateController.refresh/2 does
    payload = Orchestrator.request_refresh(orchestrator_name)
    refute payload == :unavailable
    converted = Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)
    assert is_binary(converted.requested_at)
    assert converted.requested_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert converted.queued == true
    assert converted.coalesced == false
    assert converted.operations == ["poll", "reconcile"]
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
