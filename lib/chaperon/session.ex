defmodule Chaperon.Session do
  defstruct [
    id: nil,
    results: %{},
    errors: %{},
    async_tasks: %{},
    config: %{},
    assigns: %{},
    metrics: %{},
    scenario: nil
  ]

  @type t :: %Chaperon.Session{
    id: String.t,
    results: map,
    errors: map,
    async_tasks: map,
    config: map,
    assigns: map,
    metrics: map,
    scenario: Chaperon.Scenario.t
  }

  require Logger
  alias Chaperon.Session
  alias Chaperon.Action.SpreadAsync
  import Chaperon.Timing
  import Chaperon.Util

  @default_timeout seconds(10)


  @doc """
  Concurrently spreads a given action with a given rate over a given time interval
  """
  @spec cc_spread(Session.t, atom, SpreadAsync.rate, SpreadAsync.time) :: Session.t
  def cc_spread(session, action_name, rate, interval) do
    session
    |> Session.run_action(%SpreadAsync{
      callback: {session.scenario.module, action_name},
      rate: rate,
      interval: interval
    })
  end

  @spec loop(Session.t, atom, Chaperon.Timing.duration) :: Session.t
  def loop(session, action_name, duration) do
    session
    |> run_action(%Chaperon.Action.Loop{
      action: %Chaperon.Action.Function{func: action_name},
      duration: duration
    })
  end

  @spec timeout(Session.t) :: non_neg_integer
  def timeout(session) do
    session.config[:timeout] || @default_timeout
  end

  @spec await(Session.t, atom, Task.t) :: Session.t
  def await(session, _task_name, nil), do: session

  def await(session, task_name, task = %Task{}) do
    task_session = task |> Task.await(session |> timeout)
    session
    |> remove_async_task(task_name, task)
    |> merge_async_task_result(task_session, task_name)
  end

  @spec await(Session.t, atom, [Task.t]) :: Session.t
  def await(session, task_name, tasks) when is_list(tasks) do
    tasks
    |> Enum.reduce(session, &await(&2, task_name, &1))
  end

  @spec await(Session.t, atom) :: Session.t
  def await(session, task_name) when is_atom(task_name) do
    session
    |> await(task_name, session.async_tasks[task_name])
  end

  @spec await(Session.t, [atom]) :: Session.t
  def await(session, task_names) when is_list(task_names) do
    task_names
    |> Enum.reduce(session, &await(&2, &1))
  end

  @spec await_all(Session.t, atom) :: Session.t
  def await_all(session, task_name) do
    session
    |> await(task_name, session.async_tasks[task_name])
  end

  @spec async_task(Session.t, atom) :: (Task.t | [Task.t])
  def async_task(session, action_name) do
    session.async_tasks[action_name]
  end

  @spec get(Session.t, String.t, Keyword.t) :: Session.t
  def get(session, path, params) do
    session
    |> run_action(Chaperon.Action.HTTP.get(path, params))
  end

  @spec post(Session.t, String.t, any) :: Session.t
  def post(session, path, data) do
    session
    |> run_action(Chaperon.Action.HTTP.post(path, data))
  end

  @spec put(Session.t, String.t, any) :: Session.t
  def put(session, path, data) do
    session
    |> run_action(Chaperon.Action.HTTP.put(path, data))
  end

  @spec patch(Session.t, String.t, any) :: Session.t
  def patch(session, path, data) do
    session
    |> run_action(Chaperon.Action.HTTP.patch(path, data))
  end

  @spec delete(Session.t, String.t) :: Session.t
  def delete(session, path) do
    session
    |> run_action(Chaperon.Action.HTTP.delete(path))
  end

  @spec call(Session.t, (Session.t -> Session.t)) :: Session.t
  def call(session, func) do
    session
    |> run_action(%Chaperon.Action.Function{func: func})
  end

  @spec run_action(Session.t, Chaperon.Actionable.t) :: Session.t
  def run_action(session, action) do
    case Chaperon.Actionable.run(action, session) do
      {:error, reason} ->
        Logger.error "Session.run_action failed: #{inspect reason}"
        put_in session.errors[action], reason
      {:ok, session} ->
        Logger.debug "SUCCESS #{action}"
        session
    end
  end

  @spec assign(Session.t, Keyword.t) :: Session.t
  def assign(session, assignments) do
    assignments
    |> Enum.reduce(session, fn {k, v}, session ->
      put_in session.assigns[k], v
    end)
  end

  @spec update_assign(Session.t, Keyword.t((any -> any))) :: Session.t
  def update_assign(session, assignments) do
    assignments
    |> Enum.reduce(session, fn {k, func}, session ->
      update_in session.assigns[k], func
    end)
  end

  @spec async(Session.t, atom, [any]) :: Session.t
  def async(session, func_name, args \\ []) do
    session
    |> run_action(%Chaperon.Action.Async{
      module: session.scenario.module,
      function: func_name,
      args: args
    })
  end

  @spec add_async_task(Session.t, atom, Task.t) :: Session.t
  def add_async_task(session, name, task) do
    case session.async_tasks[name] do
      nil ->
        put_in session.async_tasks[name], task
      tasks when is_list(tasks) ->
        update_in session.async_tasks[name], &[task | &1]
      _ ->
        update_in session.async_tasks[name], &[task, &1]
    end
  end

  @spec remove_async_task(Session.t, atom, Task.t) :: Session.t
  def remove_async_task(session, task_name, task) do
    case session.async_tasks[task_name] do
      nil ->
        session
      tasks when is_list(tasks) ->
        update_in session.async_tasks[task_name],
                  &List.delete(&1, task)
      _ ->
        update_in session.async_tasks,
                  &Map.delete(&1, task_name)
    end
  end

  @spec add_result(Session.t, Chaperon.Actionable.t, any) :: Session.t
  def add_result(session, action, result) do
    Logger.debug "Add result #{action} : #{result.status_code}"
    case session.results[action] do
      nil ->
        put_in session.results[action], result

      results when is_list(results) ->
        update_in session.results[action],
                  &[result | &1]

      _ ->
        update_in session.results[action],
                  &[result, &1]
    end
  end

  @spec with_response(Session.t, atom, (Session.t, any -> any)) :: Session.t
  def with_response(session, task_name, callback) do
    session = session |> await(task_name)
    for {:async, _action, resp} <- session.results[task_name] |> as_list do
      callback.(session, resp)
    end
    session
  end

  @spec async_results(Session.t, atom) :: map
  defp async_results(task_session, task_name) do
    for {k, v} <- task_session.results do
      {task_name, {:async, k, v}}
    end
    |> Enum.into(%{})
  end

  @spec async_metrics(Session.t, atom) :: map
  defp async_metrics(task_session, task_name) do
    for {k, v} <- task_session.metrics do
      {task_name, {:async, k, v}}
    end
    |> Enum.into(%{})
  end

  @spec merge_async_task_result(Session.t, Session.t, atom) :: Session.t
  defp merge_async_task_result(session, task_session, task_name) do
    session
    |> merge_results(task_session |> async_results(task_name))
    |> merge_metrics(task_session |> async_metrics(task_name))
  end

  @spec merge_results(Session.t, map) :: Session.t
  defp merge_results(session, results) do
    update_in session.results, &preserve_vals_merge(&1, results)
  end

  @spec merge_metrics(Session.t, map) :: Session.t
  defp merge_metrics(session, metrics) do
    update_in session.metrics, &preserve_vals_merge(&1, metrics)
  end

  alias Chaperon.Session.Error

  @spec ok(Session.t) :: {:ok, Session.t}
  def ok(session), do: {:ok, session}

  @spec error(Session.t, any) :: {:error, Error.t}
  def error(s, reason), do: {:error, %Error{reason: reason, session: s}}

  defmacro session ~> {func, _, nil} do
    quote do
      unquote(session)
      |> Chaperon.Session.async(unquote(func))
    end
  end

  defmacro session ~> {task_name, _, _} do
    quote do
      unquote(session)
      |> Chaperon.Session.async(unquote(task_name))
    end
  end

  defmacro session <~ {task_name, _, _} do
    quote do
      unquote(session)
      |> Chaperon.Session.await(unquote(task_name))
    end
  end

  defmacro session ~>> {task_name, _, args} do
    size = args |> Enum.count
    body = List.last(args)
    args = args |> Enum.take(size - 1)
    body = body[:do]
    callback_fn = {:fn, [], [{:->, [], [args, body]}]}

    quote do
      unquote(session)
      |> with_response(unquote(task_name), unquote(callback_fn))
    end
  end
end