defmodule DynamicServerManager.Server.Dummy do
  @behaviour DynamicServerManager.Server

  use Agent
  require Logger

  alias DynamicServerManager.Server

  @plugin :server_plugin_dummy
  @logger_metadata [plugin: :server_dummy]
  @name __MODULE__

  @default_config %{
    request_wait_time: 0,
    up: true,
    up_changes: [],
    up_responses: [],
    create_from_snapshot_response: {:ok, %{
      server: "example-identifier",
    }},
    status: :inactive,
    status_changes: [:inactive, :starting, :running],
    status_responses: [],
    #status_changes: [:destroying, :destroyed],
    info_response: {:ok, %{
      public_ip_v4: "192.168.11.33",
      external_ip_v4: "192.168.11.34",
    }},
    destroy_response: :ok,
  }

  def start_link(config \\ %{}) do
    Agent.start_link(fn -> Map.merge(@default_config, config) end, [name: @name])
  end

  def up(location) when is_atom(location) do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(div(milliseconds, 10))
    get_next_up()
  end

  def config(location, server, overrides \\ %{}) do
    {:ok, config} = Server.build_config(@plugin, location, server, overrides)
    Agent.update(@name, &Map.merge(&1, %{config: config}))
    {:ok, config}
  end

  def create_from_snapshot(specs) do
    Logger.debug fn -> {"Creating server from specs: " <> inspect(specs), @logger_metadata} end
    %{
      request_wait_time: milliseconds,
      create_from_snapshot_response: create_response,
    } = get_config()
    :timer.sleep(milliseconds)
    case create_response do
      {:ok, data} ->
        response = Map.merge(data, %{provider: :dummy, location: specs.location})
        Logger.debug fn -> {"Success creating server: " <> inspect(response), @logger_metadata} end
        {:ok, response}
      error ->
        Logger.error fn -> {"Error creating server: " <> inspect(error), @logger_metadata} end
        error
    end
    #{:error, "Some error"}
  end

  def status(_metadata) do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(div(milliseconds, 10))
    get_next_status()
  end

  def info(metadata) do
    %{
      request_wait_time: milliseconds,
      status: status,
    } = get_config()
    :timer.sleep(div(milliseconds, 10))
    case status do
      s when s in [:starting, :running] ->
        get_info_response()
      _ ->
        server_not_found(metadata.server)
    end
  end

  def destroy(metadata) do
    %{
      request_wait_time: milliseconds,
    } = get_config()
    :timer.sleep(milliseconds)
    resp = get_destroy_response()
    if resp == :ok do
      Logger.debug fn -> {"Success destroying server: " <> inspect(metadata), @logger_metadata} end
    end
  end

  def list_servers(location, minutes_old \\ nil) when is_atom(location) and (is_nil(minutes_old) or is_integer(minutes_old) and minutes_old > 0) do
    now = Timex.now
    servers = [
      %{
        server: "server-id-1",
        create_time: now,
      },
      %{
        server: "server-id-2",
        create_time: now |> Timex.shift(minutes: -30)
      },
      %{
        server: "server-id-3",
        create_time: now |> Timex.shift(minutes: -(60 * 9))
      },
    ]
    {:ok, Server.filter_servers_minutes_old(servers, minutes_old)}
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

  def get_request_wait_time() do
    Agent.get(@name, &Map.get(&1, :request_wait_time))
  end

  def update_request_wait_time(wait_time) do
    Agent.update(@name, &Map.merge(&1, %{request_wait_time: wait_time}))
  end

  def get_up() do
    Agent.get(@name, &Map.get(&1, :up))
  end

  def update_up(response) do
    Agent.update(@name, &Map.merge(&1, %{up: response}))
  end

  def get_create_from_snapshot_response() do
    Agent.get(@name, &Map.get(&1, :create_from_snapshot_response))
  end

  def update_create_from_snapshot_response(response) do
    Agent.update(@name, &Map.merge(&1, %{create_from_snapshot_response: response}))
  end

  def get_status() do
    Agent.get(@name, &Map.get(&1, :status))
  end

  def update_status(response) do
    Agent.update(@name, &Map.merge(&1, %{status: response}))
  end

  def get_info_response() do
    Agent.get(@name, &Map.get(&1, :info_response))
  end

  def update_info_response(response) do
    Agent.update(@name, &Map.merge(&1, %{info_response: response}))
  end

  def get_destroy_response() do
    Agent.get(@name, &Map.get(&1, :destroy_response))
  end

  def update_destroy_response(response) do
    Agent.update(@name, &Map.merge(&1, %{destroy_response: response}))
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

  def add_up_response(up) do
    responses = get_up_responses() ++ [up]
    Agent.update(@name, &Map.merge(&1, %{up_responses: responses}))
  end

  def get_status_changes() do
    Agent.get(@name, &Map.get(&1, :status_changes))
  end

  def update_status_changes(changes) do
    Agent.update(@name, &Map.merge(&1, %{status_changes: changes}))
  end

  def get_status_responses() do
    Agent.get(@name, &Map.get(&1, :status_responses))
  end

  def add_status_response(status) do
    responses = get_status_responses() ++ [status]
    Agent.update(@name, &Map.merge(&1, %{status_responses: responses}))
  end

  defp get_next_up() do
    %{
      up_changes: changes,
    } = get_config()
    up = case List.pop_at(changes, 0) do
      {nil, []} ->
        get_up()
      {next_up, remaining_ups} ->
        update_up_changes(remaining_ups)
        update_up(next_up)
        next_up
    end
    add_up_response(up)
    Logger.debug fn -> {"Create up change: #{up}", @logger_metadata} end
    up
  end

  defp get_next_status() do
    %{
      status_changes: changes,
    } = get_config()
    status = case List.pop_at(changes, 0) do
      {nil, []} ->
        get_status()
      {next_status, remaining_statuses} ->
        update_status_changes(remaining_statuses)
        update_status(next_status)
        next_status
    end
    add_status_response(status)
    Logger.debug fn -> {"Create status change: #{status}", @logger_metadata} end
    status
  end

  defp server_not_found(id) do
    Logger.error fn -> {"Server #{id} not found", @logger_metadata} end
    {:error, :not_found}
  end

end


