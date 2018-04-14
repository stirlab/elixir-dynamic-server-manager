defmodule DynamicServerManager.Server.CloudSigma do
  @behaviour DynamicServerManager.Server

  alias DynamicServerManager.Server
  require Logger

  @plugin :server_plugin_cloudsigma
  @timer_seconds 2
  @timer_attempts_max 30
  @logger_metadata [plugin: :server_cloudsigma]

  def up(location) when is_atom(location) do
    location_string = Server.get_location(@plugin, location).location
    client = CloudSigma.make_endpoint_client(location_string)
    capabilities_fetched = get_capabilities(client)
    case capabilities_fetched do
      {:ok, _env = %Tesla.Env{status: 200}} ->
        up = true
        Logger.debug fn -> {"Got provider up value for #{location}: #{up}", @logger_metadata} end
        up
      error ->
        Logger.error fn -> {"Error getting provider up value for location #{location}: " <> inspect(error), @logger_metadata} end
        false
    end
  end

  def config(location, server, overrides \\ %{}) do
    Server.build_config(@plugin, location, server, overrides)
  end

  def create_from_snapshot(specs) do
    client = CloudSigma.make_endpoint_client(specs.location.location)
    with {:ok, server_id} <- clone_server(client, specs.uuid, specs.location.location),
         metadata = %{
           server: server_id,
           location: specs.location,
         },
         # TODO: Remove this once tags can be specified by name.
         {:ok, specs} = translate_tags(metadata, specs),
         :ok <- create_loop_status(server_id, :unavailable, metadata),
         tags = Map.get(specs, :tags, []),
         server_data = %{
           name: specs.fqdn,
           cpu: specs.cpu,
           mem: specs.mem,
           cpu_type: Map.get(specs, :cpu_type, "intel"),
           cpu_model: Map.get(specs, :cpu_model, nil),
           cpus_instead_of_cores: Map.get(specs, :cpus_instead_of_cores, true),
           enable_numa: Map.get(specs, :enable_numa, false),
           vnc_password: Map.get(specs, :vnc_password),
           tags: tags,
         },
         {:ok, drive_uuid, name} <- update_server(client, server_id, server_data),
         :ok <- update_server_drive(client, drive_uuid, name, tags),
         :ok <- start_server(client, server_id)
    do
      {:ok, %{
        provider: :cloudsigma,
        location: specs.location,
        server: server_id,
      }}
    else
      error ->
        error
    end
  end

  def status(%{server: id, location: %{location: location}}) do
    client = CloudSigma.make_endpoint_client(location)
    info_fetched = get_server(client, id)
    case info_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        status = env.body["status"]
        case status do
          "cloning" ->
            :starting
          "starting" ->
            :starting
          "running" ->
            :running
          "stopping" ->
            :destroying
          "stopped" ->
            :stopped
          "deleting" ->
            :destroying
          "migrating" ->
            :migrating
          "unavailable" ->
            {:error, :unavailable}
        end
      {:ok, %Tesla.Env{status: 404}} ->
        :destroyed
      error ->
        message = "Error getting status for server #{id}"
        error_handler(error, message)
    end
  end

  def info(%{server: id, location: %{location: location}}) do
    client = CloudSigma.make_endpoint_client(location)
    Logger.debug fn -> {"Getting info for server #{id}", @logger_metadata} end
    info_fetched = get_server(client, id)
    case info_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        public_ip_v4 = Enum.at(env.body["runtime"]["nics"], 0)["ip_v4"]["uuid"]
        info = %{
          public_ip_v4: public_ip_v4,
        }
        Logger.debug fn -> {"Got info for server #{id}: " <> inspect(info), @logger_metadata} end
        {:ok, info}
      {:ok, %Tesla.Env{status: 404}} ->
        server_not_found(id)
      error ->
        message = "Error getting server #{id} info"
        error_handler(error, message)
    end
  end

  def destroy(%{server: id, location: %{location: location}} = metadata) do
    client = CloudSigma.make_endpoint_client(location)
    Logger.debug fn -> {"Initiating destroy for server #{id} in location #{location}", @logger_metadata} end
    with :ok <- stop_server(client, id),
         :ok <- destroy_loop_status(id, :running, metadata)
    do
      destroy_server(client, id, location)
    else
      {:error, :not_found} ->
        server_not_found(id)
      error ->
        Logger.info fn -> {"Destroying server #{id} in location #{location} anyway: " <> inspect(error), @logger_metadata} end
        destroy_server(client, id, location)
    end
  end

  def list_servers(location, minutes_old \\ nil) when is_atom(location) and (is_nil(minutes_old) or is_integer(minutes_old) and minutes_old > 0) do
    client = CloudSigma.make_endpoint_client(Server.get_location(@plugin, location).location)
    Logger.debug fn -> {"Listing servers for location #{location}", @logger_metadata} end
    server_list = CloudSigma.get(client, "/servers/detail/", query: [limit: 0])
    case server_list do
      {:ok, env = %Tesla.Env{status: 200}} ->
        Logger.debug fn -> {"Got server list for location #{location}", @logger_metadata} end
        servers = Enum.map(env.body["objects"], fn(server) ->
          if server["runtime"] do
            %{
              server: server["uuid"],
              create_time: Server.parse_datestring(server["runtime"]["active_since"]),
            }
          else
            false
          end
        end) |> Enum.filter(&(&1))
        {:ok, Server.filter_servers_minutes_old(servers, minutes_old)}
      error ->
        message = "Error listing servers for location #{location}"
        error_handler(error, message)
    end
  end

  defp get_capabilities(client) do
    CloudSigma.get(client, "/capabilities/")
  end

  defp clone_server(client, uuid, location) do
    Logger.debug fn -> {"Cloning server #{uuid} in location #{location}", @logger_metadata} end
    server_cloned = CloudSigma.post(client, "/servers/#{uuid}/action/", %{}, query: [do: "clone"])
    case server_cloned do
      {:ok, env = %Tesla.Env{status: 202}} ->
        Logger.info fn -> {"Cloned server #{uuid} in location #{location}", @logger_metadata} end
        server_id = env.body["uuid"]
        {:ok, server_id}
      error ->
        message = "Error cloning server #{uuid} in location #{location}"
        error_handler(error, message)
    end
  end

  defp update_server(client, server_id, data) do
    Logger.debug fn -> {"Updating server #{server_id} with data: " <> inspect(data), @logger_metadata} end
    server_updated = CloudSigma.put(client, "/servers/#{server_id}/", data)
    case server_updated do
      {:ok, env = %Tesla.Env{status: 200}} ->
        name = env.body["name"]
        drive = env.body["drives"] |> Enum.at(0)
        drive_uuid = drive["drive"]["uuid"]
        Logger.debug fn -> {"Updated server #{server_id}, #{name}", @logger_metadata} end
        {:ok, drive_uuid, name}
      error ->
        message = "Error updating server #{server_id}"
        error_handler(error, message)
    end
  end

  defp get_server_drive(client, uuid) do
     CloudSigma.get(client, "/drives/#{uuid}/")
  end

  defp update_server_drive(client, drive_uuid, name, tags) do
    Logger.debug fn -> {"Fetching drive #{drive_uuid} info", @logger_metadata} end
    info_fetched = get_server_drive(client, drive_uuid)
    case info_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        drive_size = env.body["size"]
        drive_data = %{
          name: name,
          tags: tags,
          # These values are required by the API, so pass back in what was
          # retrieved.
          media: "disk",
          size: drive_size,
        }
        Logger.debug fn -> {"Updating drive #{drive_uuid} info" <> inspect(drive_data), @logger_metadata} end
        drive_updated = CloudSigma.put(client, "/drives/#{drive_uuid}/", drive_data)
        case drive_updated do
          {:ok, %Tesla.Env{status: 200}} ->
            Logger.debug fn -> {"Drive #{drive_uuid} info updated", @logger_metadata} end
            :ok
          update_drive_error ->
            update_drive_error_message = "Error updating drive #{drive_uuid} info"
            error_handler(update_drive_error, update_drive_error_message)
        end
      get_drive_error ->
        get_drive_error_message = "Error fetching drive #{drive_uuid} info"
        error_handler(get_drive_error, get_drive_error_message)
    end
  end

  defp start_server(client, server_id) do
    Logger.debug fn -> {"Starting server #{server_id}", @logger_metadata} end
    server_started = CloudSigma.post(client, "/servers/#{server_id}/action/", %{}, query: [do: "start"])
    case server_started do
      {:ok, %Tesla.Env{status: 202}} ->
        Logger.debug fn -> {"Started server #{server_id}", @logger_metadata} end
        :ok
      error ->
        message = "Error starting server #{server_id}"
        error_handler(error, message)
    end
  end

  defp stop_server(client, server_id) do
    Logger.debug fn -> {"Stopping server #{server_id}", @logger_metadata} end
    server_stopped = CloudSigma.post(client, "/servers/#{server_id}/action/", %{}, query: [do: "stop"])
    case server_stopped do
      {:ok, %Tesla.Env{status: 202}} ->
        Logger.debug fn -> {"Stopped server #{server_id}", @logger_metadata} end
        :ok
      {:ok, %Tesla.Env{status: 404}} ->
        server_not_found(server_id)
      error ->
        Logger.error fn -> {"Error stopping server #{server_id}: " <> inspect(error), @logger_metadata} end
        error
    end
  end

  defp destroy_server(client, server_id, location) do
    Logger.debug fn -> {"Destroying server #{server_id} in location #{location}", @logger_metadata} end
    destroyed = CloudSigma.delete(client, "/servers/#{server_id}/", query: [recurse: "all_drives"])
    case destroyed do
      {:ok, %Tesla.Env{status: 204}} ->
        Logger.info fn -> {"Destroyed server #{server_id} in location #{location}", @logger_metadata} end
        :ok
      error ->
        message = "Error destroying server #{server_id} in location #{location}"
        error_handler(error, message)
    end
  end

  defp map_tag_name_to_uuid(name, tag_info) do
    Enum.reduce tag_info, false, fn(tag, uuid) ->
      if uuid do
        uuid
      else
        if tag["name"] == name, do: tag["uuid"], else: false;
      end
    end
  end

  defp translate_tags(%{location: %{location: location}}, specs) do
    client = CloudSigma.make_endpoint_client(location)
    Logger.debug fn -> {"Getting tag info for datacenter #{location}", @logger_metadata} end
    tags_fetched = CloudSigma.get(client, "/tags/")
    case tags_fetched do
      {:ok, %Tesla.Env{status: 200, body: %{"objects" => tag_info}}} ->
        Logger.debug fn -> {"Got tag info for datacenter #{location}", @logger_metadata} end
        uuid_tags = Enum.map specs.tags, fn(name) ->
          map_tag_name_to_uuid(name, tag_info)
        end
        tags_filtered = Enum.filter uuid_tags, fn(tag) ->
          tag != false
        end
        {:ok, Map.put(specs, :tags, tags_filtered)}
      error ->
        message = "Error getting datacenter #{location} tag info"
        error_handler(error, message)
    end
  end

  defp get_server(client, server_id) do
    CloudSigma.get(client, "/servers/#{server_id}/")
  end

  defp create_loop_status(server_id, status, metadata) do
    create_loop_status(server_id, status, metadata, 1)
  end

  defp create_loop_status(server_id, {:error, error}, _metadata, _count) do
    Logger.error fn -> {"Creating server #{server_id} status check failed: " <> inspect(error), @logger_metadata} end
    {:error, error}
  end

  defp create_loop_status(server_id, :stopped, _metadata, _count) do
    Logger.debug fn -> {"Creating server #{server_id} status now stopped", @logger_metadata} end
    :ok
  end

  defp create_loop_status(server_id, status, metadata, count) do
    Logger.debug fn -> {"Creating server #{server_id} status is #{status}, waiting on status stopped, attempt ##{count}", @logger_metadata} end
    :timer.sleep(:timer.seconds(@timer_seconds))
    next_status = status(metadata)
    if count >= @timer_attempts_max do
      Logger.error fn -> {"Creating server #{server_id} status is #{status}, waiting on status stopped, max attempts #{@timer_attempts_max} exceeded", @logger_metadata} end
      {:error, :max_attempts_exceeded}
    else
      create_loop_status(server_id, next_status, metadata, count + 1)
    end
  end

  defp destroy_loop_status(server_id, status, metadata) do
    destroy_loop_status(server_id, status, metadata, 1)
  end

  defp destroy_loop_status(server_id, {:error, error}, _metadata, _count) do
    Logger.error fn -> {"Destroying server #{server_id} status check failed: " <> inspect(error), @logger_metadata} end
    {:error, error}
  end

  defp destroy_loop_status(server_id, :stopped, _metadata, _count) do
    Logger.debug fn -> {"Destroying server #{server_id} status now stopped", @logger_metadata} end
    :ok
  end

  defp destroy_loop_status(server_id, status, metadata, count) do
    Logger.debug fn -> {"Destroying server #{server_id} status is #{status}, waiting on status stopped, attempt ##{count}", @logger_metadata} end
    :timer.sleep(:timer.seconds(@timer_seconds))
    next_status = status(metadata)
    if count >= @timer_attempts_max do
      Logger.error fn -> {"Destroying server #{server_id} status is #{status}, waiting on status stopped, max attempts #{@timer_attempts_max} exceeded", @logger_metadata} end
      {:error, :max_attempts_exceeded}
    else
      destroy_loop_status(server_id, next_status, metadata, count + 1)
    end
  end

  defp server_not_found(id) do
    Logger.error fn -> {"Server #{id} not found", @logger_metadata} end
    {:error, :not_found}
  end

  defp error_handler(response, message) do
    case response do
      {:ok, %Tesla.Env{status: _status, body: body}} ->
        Logger.error fn -> {message <> ": " <> inspect(body), @logger_metadata} end
        {:error, body}
      {:error, error} ->
        Logger.error fn -> {message <> ": " <> inspect(error), @logger_metadata} end
        {:error, error}
    end
  end

end

