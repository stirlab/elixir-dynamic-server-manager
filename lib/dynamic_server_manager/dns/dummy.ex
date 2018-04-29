defmodule DynamicServerManager.Dns.Dummy do
  @behaviour DynamicServerManager.Dns

  use Agent
  require Logger

  @logger_metadata [plugin: :dns_dummy]
  @name __MODULE__

  @default_config %{
    request_wait_time: 0,
    up_response: true,
    up_changes: [true],
    up_responses: [],
    get_record_response: {:ok, %{
      type: :a,
      ttl: 60,
      ip: "192.168.11.34",
    }},
    create_ipv4_record_response: :ok,
    create_ipv4_record_changes: [:ok],
    create_ipv4_record_responses: [],
    delete_ipv4_record_response: :ok,
    delete_ipv4_record_changes: [:ok],
    delete_ipv4_record_responses: [],
  }

  def start_link(config \\ %{}) do
    Agent.start_link(fn -> Map.merge(@default_config, config) end, [name: @name])
  end

  def up() do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(div(milliseconds, 10))
    get_next_response("up")
  end

  def get_record(_zone_name, _hostname) do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(milliseconds)
    get_get_record_response()
  end

  def create_ipv4_record(_zone_name, _hostname, _ip) do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(milliseconds)
    get_next_response("create_ipv4_record")
  end

  def delete_ipv4_record(_zone_name, _hostname) do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(milliseconds)
    get_next_response("delete_ipv4_record")
  end

  def get_config() do
    Agent.get(@name, &(&1))
  end

  def update_config(config) do
    Agent.update(@name, &Map.merge(&1, config))
  end

  def reset_config(config \\ %{}) do
    Agent.update(@name, fn(_state) -> Map.merge(@default_config, config) end)
  end

  def get_up_response() do
    Agent.get(@name, &Map.get(&1, :up_response))
  end

  def update_up_response(response) do
    Agent.update(@name, &Map.merge(&1, %{up_response: response}))
  end

  def get_up_changes() do
    Agent.get(@name, &Map.get(&1, :up_changes))
  end

  def update_up_changes(changes) do
    Agent.update(@name, &Map.merge(&1, %{up_changes: changes}))
  end

  def get_up_responses() do
    Agent.get(@name, &Map.get(&1, :up_responses))
  end

  def add_up_response(response) do
    responses = get_up_responses() ++ [response]
    Agent.update(@name, &Map.merge(&1, %{up_responses: responses}))
  end

  def get_get_record_response() do
    Agent.get(@name, &Map.get(&1, :get_record_response))
  end

  def update_get_record_response(response) do
    Agent.update(@name, &Map.merge(&1, %{get_record_response: response}))
  end

  def get_create_ipv4_record_response() do
    Agent.get(@name, &Map.get(&1, :create_ipv4_record_response))
  end

  def update_create_ipv4_record_response(response) do
    Agent.update(@name, &Map.merge(&1, %{create_ipv4_record_response: response}))
  end

  def get_create_ipv4_record_changes() do
    Agent.get(@name, &Map.get(&1, :create_ipv4_record_changes))
  end

  def update_create_ipv4_record_changes(changes) do
    Agent.update(@name, &Map.merge(&1, %{create_ipv4_record_changes: changes}))
  end

  def get_create_ipv4_record_responses() do
    Agent.get(@name, &Map.get(&1, :create_ipv4_record_responses))
  end

  def add_create_ipv4_record_response(response) do
    responses = get_create_ipv4_record_responses() ++ [response]
    Agent.update(@name, &Map.merge(&1, %{create_ipv4_record_responses: responses}))
  end

  def get_delete_ipv4_record_response() do
    Agent.get(@name, &Map.get(&1, :delete_ipv4_record_response))
  end

  def update_delete_ipv4_record_response(response) do
    Agent.update(@name, &Map.merge(&1, %{delete_ipv4_record_response: response}))
  end

  def get_delete_ipv4_record_changes() do
    Agent.get(@name, &Map.get(&1, :delete_ipv4_record_changes))
  end

  def update_delete_ipv4_record_changes(changes) do
    Agent.update(@name, &Map.merge(&1, %{delete_ipv4_record_changes: changes}))
  end

  def get_delete_ipv4_record_responses() do
    Agent.get(@name, &Map.get(&1, :delete_ipv4_record_responses))
  end

  def add_delete_ipv4_record_response(response) do
    responses = get_delete_ipv4_record_responses() ++ [response]
    Agent.update(@name, &Map.merge(&1, %{delete_ipv4_record_responses: responses}))
  end

  defp get_next_response(type) do
    changes_string = type <> "_changes"
    response_string = type <> "_response"
    changes = Map.get(get_config(), String.to_atom(changes_string))
    response = case List.pop_at(changes, 0) do
      {nil, []} ->
        apply(@name, String.to_atom("get_" <> response_string), [])
      {next_response, remaining_responses} ->
        apply(@name, String.to_atom("update_" <> changes_string), [remaining_responses])
        apply(@name, String.to_atom("update_" <> response_string), [next_response])
        next_response
    end
    apply(@name, String.to_atom("add_" <> response_string), [response])
    Logger.debug fn -> {"#{response_string} change: #{inspect(response)}", @logger_metadata} end
    response
  end

end

