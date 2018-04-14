defmodule DynamicServerManager.Server.ProfitBricks do
  @behaviour DynamicServerManager.Server

  alias DynamicServerManager.Server
  require Logger

  @plugin :server_plugin_profitbricks
  @timer_seconds 5
  @timer_attempts_max 180
  @logger_metadata [plugin: :server_profitbricks]

  def up(location) when is_atom(location) do
    region_location = Server.get_location(@plugin, location).region_location
    location_fetched = get_location(region_location)
    case location_fetched do
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
    with {:ok, datacenter_id} <- create_datacenter(specs),
         {:ok, lan_id} <- create_lan(datacenter_id, specs.fqdn),
         {:ok, volume_id} <- create_volume(datacenter_id, specs.image, specs.fqdn, specs.size),
         :ok <- volume_check_state_available(datacenter_id, volume_id, "INACTIVE"),
         {:ok, server_id} <- create_server(datacenter_id, specs.fqdn, specs.cpuFamily, specs.cores, specs.ram, volume_id, lan_id)
    do
      {:ok, %{
        provider: :profitbricks,
        location: %{
          region_location: specs.location.region_location,
          datacenter: datacenter_id,
        },
        server: server_id,
      }}
    else
      error ->
        error
    end
  end

  def status(%{server: server_id} = metadata) do
    datacenter_id = get_datacenter_id(metadata)
    info_fetched = get_server(datacenter_id, server_id)
    case info_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        server_state = env.body["metadata"]["state"]
        vm_state = env.body["properties"]["vmState"]
        case server_state do
          "AVAILABLE" ->
            case vm_state do
              "NOSTATE" ->
                :starting
              "RUNNING" ->
                :running
              "BLOCKED" ->
                {:error, :blocked}
              "PAUSED" ->
                {:error, :paused}
              "SHUTDOWN" ->
                :destroying
              "SHUTOFF" ->
                :destroying
              "CRASHED" ->
                {:error, :crashed}
            end
          "BUSY" ->
            case vm_state do
              "NOSTATE" ->
                :starting
              "RUNNING" ->
                :starting
              "BLOCKED" ->
                {:error, :blocked}
              "PAUSED" ->
                {:error, :paused}
              "SHUTDOWN" ->
                :destroying
              "SHUTOFF" ->
                :starting
              "CRASHED" ->
                {:error, :crashed}
            end
          "INACTIVE" ->
            case vm_state do
              "NOSTATE" ->
                :starting
              "RUNNING" ->
                {:error, :impossible_state}
              "BLOCKED" ->
                {:error, :blocked}
              "PAUSED" ->
                {:error, :paused}
              "SHUTDOWN" ->
                {:error, :impossible_state}
              "SHUTOFF" ->
                :starting
              "CRASHED" ->
                {:error, :crashed}
            end
        end
      {:ok, %Tesla.Env{status: 404}} ->
        :destroyed
      error ->
        message = "Error getting status for server #{server_id}"
        error_handler(error, message)
    end
  end

  def info(%{server: server_id} = metadata) do
    datacenter_id = get_datacenter_id(metadata)
    Logger.debug fn -> {"Getting info for server #{server_id}", @logger_metadata} end
    nics_fetched = get_server_nics(datacenter_id, server_id)
    case nics_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        nic = env.body["items"] |> Enum.at(0)
        public_ip_v4 = nic["properties"]["ips"] |> Enum.at(0)
        info = %{
          public_ip_v4: public_ip_v4,
        }
        Logger.debug fn -> {"Got info for server #{server_id}: " <> inspect(info), @logger_metadata} end
        {:ok, info}
      {:ok, %Tesla.Env{status: 404}} ->
        server_not_found(server_id)
      error ->
        message = "Error getting server #{server_id} info"
        error_handler(error, message)
    end
  end

  def list_servers(location, minutes_old \\ nil) when is_atom(location) and (is_nil(minutes_old) or is_integer(minutes_old) and minutes_old > 0) do
    Logger.debug fn -> {"Listing servers for location #{location}", @logger_metadata} end
    location_map = Server.get_location(@plugin, location)
    datacenter_list = ProfitBricks.get("/datacenters", query: [{:"filter.location", location_map.region_location}, {:depth, 3}])
    case datacenter_list do
      {:ok, env = %Tesla.Env{status: 200}} ->
        servers = Enum.map(env.body["items"], fn(datacenter) ->
          if datacenter["id"] == location_map.base_datacenter do
            false
          else
            Enum.map(datacenter["entities"]["servers"]["items"], fn(server) ->
              %{
                server: server["id"],
                create_time: Server.parse_datestring(server["metadata"]["createdDate"]),
              }
            end)
          end
        end) |> Enum.filter(&(&1)) |> List.flatten
        Logger.debug fn -> {"Got server list for location #{location}", @logger_metadata} end
        {:ok, Server.filter_servers_minutes_old(servers, minutes_old)}
      error ->
        message = "Error listing servers for location #{location}"
        error_handler(error, message)
    end
  end

  def destroy(%{server: server_id} = metadata) do
    datacenter_id = get_datacenter_id(metadata)
    if datacenter_id == get_default_datacenter_id() do
      destroy_server_and_components(datacenter_id, server_id)
    else
      destroy_datacenter(datacenter_id)
    end
  end

  defp get_location(region_location) do
    ProfitBricks.get("/locations/#{region_location}")
  end

  defp destroy_server_and_components(datacenter_id, server_id) do
    Logger.debug fn -> {"Initiating destroy for server #{server_id}, in datacenter #{datacenter_id}", @logger_metadata} end
    lan_id = get_server_lan_from_nic(datacenter_id, server_id)
    volume_id = get_server_volume(datacenter_id, server_id)
    compute_destroy = destroy_server_compute(datacenter_id, server_id)
    compute_destroyed = check_server_compute_destroyed(datacenter_id, server_id)
    case compute_destroyed do
      :ok ->
        lan_destroy = if lan_id == nil do
          :ok
        else
          destroy_server_lan(datacenter_id, lan_id)
        end
        volume_destroy = if volume_id == nil do
          :ok
        else
          destroy_server_volume(datacenter_id, volume_id)
        end
        case {compute_destroy, lan_destroy, volume_destroy} do
          {:ok, :ok, :ok} ->
            :ok
          {_compute_error, :ok, :ok} ->
            {:error, %{compute: server_id}}
          {:ok, _lan_error, :ok} ->
            {:error, %{lan: lan_id}}
          {:ok, :ok, _volume_error} ->
            {:error, %{volume: volume_id}}
          {_compute_error, _lan_error, :ok} ->
            {:error, %{compute: server_id, lan: lan_id}}
          {:ok, _lan_error, _volume_error} ->
            {:error, %{lan: lan_id, volume: volume_id}}
          {_compute_error, :ok, _volume_error} ->
            {:error, %{compute: server_id, volume: volume_id}}
          _all ->
            {:error, %{compute: server_id, lan: lan_id, volume: volume_id}}
        end
      error ->
        error
    end
  end

  defp destroy_datacenter(id) do
    Logger.debug fn -> {"Destroying datacenter #{id}", @logger_metadata} end
    datacenter_deleted = ProfitBricks.delete("/datacenters/#{id}")
    case datacenter_deleted do
      {:ok, %Tesla.Env{status: 202}} ->
        Logger.info fn -> {"Destroyed datacenter #{id}", @logger_metadata} end
        :ok
      error ->
        message = "Error destroying datacenter #{id}"
        error_handler(error, message)
    end
  end

  defp get_default_datacenter_id() do
    Application.fetch_env!(:dynamic_server_manager, @plugin) |> Keyword.get(:datacenter)
  end

  defp get_datacenter_id(%{location: location}) do
    case Map.get(location, :datacenter) do
      nil ->
        get_default_datacenter_id()
      datacenter_id ->
        datacenter_id
    end
  end

  defp get_server(datacenter_id, id) do
    ProfitBricks.get(make_datacenter_endpoint_path(datacenter_id, "/servers/#{id}"))
  end

  defp check_server_compute_destroyed(datacenter_id, id) do
    check_server_compute_destroyed(datacenter_id, id, 1)
  end

  defp check_server_compute_destroyed(datacenter_id, id, count) do
    Logger.debug fn -> {"Checking if server #{id} destroyed, attempt ##{count}", @logger_metadata} end
    :timer.sleep(:timer.seconds(@timer_seconds))
    server_info = get_server(datacenter_id, id)
    case server_info do
      {:ok, %Tesla.Env{status: 404}} ->
        Logger.info fn -> {"Server #{id} destroyed", @logger_metadata} end
        :ok
      _ ->
        if count >= @timer_attempts_max do
          Logger.error fn -> {"Checking server #{id} destroyed, max attempts #{@timer_attempts_max} exceeded", @logger_metadata} end
          {:error, "Checking server #{id} destroyed max attempts #{@timer_attempts_max} exceeded"}
        else
          check_server_compute_destroyed(datacenter_id, id, count + 1)
        end
    end
  end

  defp get_server_nics(datacenter_id, server_id) do
    Logger.debug fn -> {"Getting NIC data for server #{server_id}", @logger_metadata} end
    ProfitBricks.get(make_datacenter_endpoint_path(datacenter_id, "/servers/#{server_id}/nics"), query: [depth: 2])
  end

  defp get_server_lan_from_nic(datacenter_id, server_id) do
    nics_fetched = get_server_nics(datacenter_id, server_id)
    case nics_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        Logger.debug fn -> {"Retrieved NIC data for server #{server_id}", @logger_metadata} end
        nic = env.body["items"] |> Enum.at(0)
        lan_id = if (nic), do: nic["properties"]["lan"], else: nil
        lan_id
      error ->
        message = "Error getting NIC data for server #{server_id}"
        error_handler(error, message)
    end
  end

  defp get_volume_state(datacenter_id, id) do
    info_fetched = ProfitBricks.get(make_datacenter_endpoint_path(datacenter_id, "/volumes/#{id}"))
    case info_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        state = env.body["metadata"]["state"]
        {:ok, state}
      {:ok, %Tesla.Env{status: 404}} ->
        Logger.warn fn -> {"Volume #{id} not found, trying again in case it's still pending creation", @logger_metadata} end
        {:ok, "INACTIVE"}
      {:error, %Tesla.Error{reason: :socket_closed_remotely}} ->
        Logger.warn fn -> {"Socket disconnect, trying again", @logger_metadata} end
        {:ok, "BUSY"}
      error ->
        message = "Error getting volume #{id} state"
        error_handler(error, message)
    end
  end

  defp get_server_volume(datacenter_id, server_id) do
    Logger.debug fn -> {"Getting volume data for server #{server_id}", @logger_metadata} end
    volumes_fetched = ProfitBricks.get(make_datacenter_endpoint_path(datacenter_id, "/servers/#{server_id}/volumes"))
    case volumes_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        Logger.debug fn -> {"Retrieved volume data for server #{server_id}", @logger_metadata} end
        volume = env.body["items"] |> Enum.at(0)
        volume_id = if (volume), do: volume["id"], else: nil
        volume_id
      error ->
        message = "Error getting volume data for server #{server_id}"
        error_handler(error, message)
    end
  end

  defp create_datacenter(specs) do
    datacenter = Map.get(specs, :datacenter)
    if datacenter == specs.location.base_datacenter do
      {:ok, datacenter}
    else
      Logger.debug fn -> {"Creating datacenter for #{specs.fqdn} in location #{specs.location.region_location}", @logger_metadata} end
      data = %{
        properties: %{
          name: specs.fqdn,
          location: specs.location.region_location,
        },
      }
      datacenter_created = ProfitBricks.post("/datacenters", data)
      case datacenter_created do
        {:ok, env = %Tesla.Env{status: 202}} ->
          datacenter_id = env.body["id"]
          Logger.info fn -> {"Created datacenter #{datacenter_id} for #{specs.fqdn} in location #{specs.location.region_location}", @logger_metadata} end
          {:ok, datacenter_id}
        error ->
          message = "Error creating datacenter for #{specs.fqdn} in location #{specs.location.region_location}"
          error_handler(error, message)
      end
    end
  end

  defp create_lan(datacenter_id, name) do
    Logger.debug fn -> {"Creating LAN for #{name}", @logger_metadata} end
    data = %{
      properties: %{
        name: name,
        public: true,
      }
    }
    lan_created = ProfitBricks.post(make_datacenter_endpoint_path(datacenter_id, "/lans"), data)
    case lan_created do
      {:ok, env = %Tesla.Env{status: 202}} ->
        Logger.debug fn -> {"Created LAN for #{name}", @logger_metadata} end
        lan_id = env.body["id"]
        {:ok, lan_id}
      error ->
        message = "Error creating LAN for #{name}"
        error_handler(error, message)
    end
  end

  defp create_volume(datacenter_id, id, name, size) do
    Logger.debug fn -> {"Creating volume from snapshot #{id}", @logger_metadata} end
    data = %{
      properties: %{
        name: name,
        size: size,
        image: id,
        type: "HDD",
      }
    }
    volume_created = ProfitBricks.post(make_datacenter_endpoint_path(datacenter_id, "/volumes"), data)
    case volume_created do
      {:ok, env = %Tesla.Env{status: 202}} ->
        volume_id = env.body["id"]
        Logger.debug fn -> {"Created volume #{volume_id} from snapshot #{id}", @logger_metadata} end
        {:ok, volume_id}
      error ->
        message = "Error creating volume from snapshot #{id}"
        error_handler(error, message)
    end
  end

  defp volume_check_state_available(datacenter_id, id, state) do
    volume_check_state_available(datacenter_id, id, state, 1)
  end

  defp volume_check_state_available(datacenter_id, id, state, count) do
    Logger.debug fn -> {"Checking volume #{id} for state AVAILABLE, current state is #{state}, attempt ##{count}", @logger_metadata} end
    :timer.sleep(:timer.seconds(@timer_seconds))
    info_fetched = get_volume_state(datacenter_id, id)
    case info_fetched do
      {:ok, next_state} ->
        if next_state == "AVAILABLE" do
          Logger.debug fn -> {"Volume #{id} state now AVAILABLE", @logger_metadata} end
          :ok
        else
          if count >= @timer_attempts_max do
            Logger.error fn -> {"Checking volume #{id} for state AVAILABLE, current state is #{next_state}, max attempts #{@timer_attempts_max} exceeded", @logger_metadata} end
            {:error, "Checking volume #{id} for state AVAILABLE max attempts #{@timer_attempts_max} exceeded"}
          else
            volume_check_state_available(datacenter_id, id, next_state, count + 1)
          end
        end
      error ->
        error
    end
  end

  defp create_server(datacenter_id, name, cpuFamily, cores, ram, volume_id, lan_id) do
    Logger.debug fn -> {"Creating server #{name} in datacenter #{datacenter_id} using LAN ID #{lan_id}, volume ID #{volume_id}", @logger_metadata} end
    data = %{
      properties: %{
        cores: cores,
        ram: ram,
        name: name,
        cpuFamily: cpuFamily,
        bootVolume: %{
          id: volume_id,
        },
      },
      entities: %{
        nics: %{
          items: [
            %{
              properties: %{
                name: name,
                dhcp: true,
                lan: lan_id,
                nat: false,
              },
            },
          ],
        },
      },
    }
    server_created = ProfitBricks.post(make_datacenter_endpoint_path(datacenter_id, "/servers"), data)
    case server_created do
      {:ok, env = %Tesla.Env{status: 202}} ->
        Logger.info fn -> {"Created server #{name}", @logger_metadata} end
        server_id = env.body["id"]
        {:ok, server_id}
      error ->
        message = "Error creating server for #{name}"
        error_handler(error, message)
    end
  end

  defp destroy_server_lan(datacenter_id, id) do
    Logger.debug fn -> {"Destroying server LAN #{id}", @logger_metadata} end
    lan_deleted = ProfitBricks.delete(make_datacenter_endpoint_path(datacenter_id, "/lans/#{id}"))
    case lan_deleted do
      {:ok, %Tesla.Env{status: 202}} ->
        Logger.debug fn -> {"Destroyed server LAN #{id}", @logger_metadata} end
        :ok
      error ->
        message = "Error destroying server LAN #{id}"
        error_handler(error, message)
    end
  end

  defp destroy_server_volume(datacenter_id, id) do
    Logger.debug fn -> {"Destroying server drive #{id}", @logger_metadata} end
    drive_deleted = ProfitBricks.delete(make_datacenter_endpoint_path(datacenter_id, "/volumes/#{id}"))
    case drive_deleted do
      {:ok, %Tesla.Env{status: 202}} ->
        Logger.info fn -> {"Destroyed server drive #{id}", @logger_metadata} end
        :ok
      error ->
        message = "Error destroying server drive #{id}"
        error_handler(error, message)
    end
  end

  defp destroy_server_compute(datacenter_id, id) do
    Logger.debug fn -> {"Destroying server #{id}", @logger_metadata} end
    server_deleted = ProfitBricks.delete(make_datacenter_endpoint_path(datacenter_id, "/servers/#{id}"))
    case server_deleted do
      {:ok, %Tesla.Env{status: 202}} ->
        Logger.info fn -> {"Destroyed server #{id}", @logger_metadata} end
        :ok
      error ->
        message = "Error destroying server #{id}"
        error_handler(error, message)
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

  defp make_datacenter_endpoint_path(datacenter, path) do
    "/datacenters/#{datacenter}" <> path
  end

end

