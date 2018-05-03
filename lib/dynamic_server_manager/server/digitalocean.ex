defmodule DynamicServerManager.Server.DigitalOcean do
  @behaviour DynamicServerManager.Server

  alias DynamicServerManager.Server
  require Logger

  @plugin :server_plugin_digitalocean
  @logger_metadata [plugin: :server_digitalocean]

  def up(location) when is_atom(location) do
    region = Server.get_location(@plugin, location).region
    regions_fetched = get_regions()
    case regions_fetched do
      {:ok, env = %Tesla.Env{status: 200}} ->
        region_available = Enum.find(env.body["regions"], fn(r) ->
          r["slug"] == region and r["available"] === true
        end)
        up = region_available != nil
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
    data = %{
      name: specs.fqdn,
      image: specs.image,
      size: specs.size,
      region: specs.location.region,
      private_networking: Map.get(specs, :private_networking, false),
      ipv6: Map.get(specs, :ipv6, false),
      backups: Map.get(specs, :backups, false),
      monitoring: Map.get(specs, :monitoring, false),
      user_data: Map.get(specs, :user_data, ""),
    }
    Logger.debug fn -> {"Creating server from snapshot #{specs.image} in region #{specs.location.region}, data: " <> inspect(data), @logger_metadata} end
    response = DigitalOcean.post("/droplets", data)
    case response do
      {:ok, env = %Tesla.Env{status: 202}} ->
        server_id = env.body["droplet"]["id"]
        Logger.info fn -> {"Created server #{server_id} from snapshot #{specs.image} in region #{specs.location.region}", @logger_metadata} end
        {:ok, %{
          provider: :digitalocean,
          location: specs.location,
          server: server_id,
        }}
      error ->
        message = "Error creating server from snapshot #{specs.image} in region #{specs.location.region}"
        error_handler(error, message)
    end
  end

  def status(%{server: id}) do
    response = get_server(id)
    case response do
      {:ok, env = %Tesla.Env{status: 200}} ->
        status = env.body["droplet"]["status"]
        case status do
          "new" ->
            :starting
          "active" ->
            :running
          "off" ->
            :destroying
          "archive" ->
            :destroying
        end
      {:ok, %Tesla.Env{status: 404}} ->
        :destroyed
      error ->
        message = "Error getting status for server #{id}"
        error_handler(error, message)
    end
  end

  def info(%{server: id}) do
    Logger.debug fn -> {"Getting info for server #{id}", @logger_metadata} end
    response = get_server(id)
    case response do
      {:ok, env = %Tesla.Env{status: 200}} ->
        public_ip_v4 = env.body["droplet"]["networks"]["v4"] |> Enum.at(0) |> Map.fetch!("ip_address")
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

  def destroy(%{server: id, location: %{region: region}}) do
    Logger.debug fn -> {"Destroying server #{id} in region #{region}", @logger_metadata} end
    response = DigitalOcean.delete("/droplets/#{id}")
    case response do
      {:ok, %Tesla.Env{status: 204}} ->
        Logger.info fn -> {"Destroyed server #{id} in region #{region}", @logger_metadata} end
        :ok
      {:ok, %Tesla.Env{status: 404}} ->
        server_not_found(id)
      error ->
        message = "Error destroying server #{id} in region #{region}"
        error_handler(error, message)
    end
  end

  def list_servers(location, minutes_old \\ nil) when is_atom(location) and (is_nil(minutes_old) or is_integer(minutes_old) and minutes_old > 0) do
    Logger.debug fn -> {"Listing servers for location #{location}", @logger_metadata} end
    region = Server.get_location(@plugin, location).region
    # TODO: Refactor to get paged results.
    response = DigitalOcean.get("/droplets", query: [per_page: 200])
    case response do
      {:ok, env = %Tesla.Env{status: 200}} ->
        Logger.debug fn -> {"Got server list for region #{region}", @logger_metadata} end
        servers = Enum.map(env.body["droplets"], fn(server) ->
          r = Map.get(server, "region") |> Map.get("slug")
          if r == region do
            %{
              server: server["id"],
              create_time: Server.parse_datestring(server["created_at"]),
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

  defp get_regions() do
    DigitalOcean.get("/regions")
  end

  defp get_server(id) do
    DigitalOcean.get("/droplets/#{id}")
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


