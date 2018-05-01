defmodule DynamicServerManager.Server do
  @type location :: atom()
  @type server :: atom() # :small | :medium | :large
  @type overrides :: Map.t
  @type config :: Map.t
  @type specs :: Map.t
  @type metadata :: Map.t
  @type ip :: String.t
  @type info :: %{public_ip_v4: ip} | %{public_ip_v4: ip, external_ip_v4: ip}
  @type status :: [:inactive | :starting | :running | :destroying | :destroyed | :migrating]
  @type server_id :: String.t
  @type minutes_old :: non_neg_integer() | nil
  @type server_list :: [] | [server_id, ...]

  @callback up(location) :: boolean()
  @callback config(location, server, overrides) :: config
  @callback create_from_snapshot(specs) :: {:ok, metadata} | {:error, String.t}
  @callback status(metadata) :: status | {:error, String.t}
  @callback info(metadata) :: {:ok, info} | {:error, String.t}
  @callback destroy(metadata) :: :ok | {:error, String.t}
  @callback list_servers(location, minutes_old) :: server_list

  require Logger

  def up(provider_label, location) do
    provider = get_module(provider_label)
    provider.up(location)
  end

  def config(provider_label, location, server, overrides \\ %{}) do
    provider = get_module(provider_label)
    provider.config(location, server, overrides)
  end

  def create_from_snapshot(provider_label, specs) do
    provider = get_module(provider_label)
    provider.create_from_snapshot(specs)
  end

  def status(provider_label, metadata) do
    provider = get_module(provider_label)
    provider.status(metadata)
  end

  def info(provider_label, metadata) do
    provider = get_module(provider_label)
    provider.info(metadata)
  end

  def destroy(provider_label, metadata) do
    provider = get_module(provider_label)
    provider.destroy(metadata)
  end

  def list_servers(provider_label, location, minutes_old \\ nil) do
    provider = get_module(provider_label)
    provider.list_servers(location, minutes_old)
  end

  def build_config(key, location, server, overrides \\ %{}) do
    provider = Application.fetch_env!(:dynamic_server_manager, key)
    locations = Keyword.get(provider, :locations)
    servers = Keyword.get(provider, :servers)
    location_result = Map.fetch(locations, location)
    server_result = Map.fetch(servers, server)
    case {location_result, server_result} do
      {{:ok, location_config}, {:ok, server_config}} ->
        final_config = server_config |> Map.merge(%{location: location_config}) |> Map.merge(overrides)
        Logger.debug fn -> "Generated config #{key}, #{location}, #{server}: " <> inspect(final_config) end
        {:ok, final_config}
      error ->
        Logger.error fn -> "Error generating config #{key}, #{location}, #{server}: " <> inspect(error) end
        error
    end
  end

  def get_location(key, location) when is_atom(location) do
    Application.fetch_env!(:dynamic_server_manager, key) |> Keyword.get(:locations) |> Map.fetch!(location)
  end

  def get_module(provider) when is_atom(provider) do
    Application.fetch_env!(:dynamic_server_manager, :server_module_map) |> Map.fetch!(provider)
  end

  def make_hostname(prefix \\ "server") do
    prefix <> "-" <> UUID.uuid4()
  end

  def parse_datestring(string, format \\ "{ISO:Extended:Z}") do
    Timex.parse!(string, format)
  end

  def filter_servers_minutes_old(servers, nil) do
    servers
  end

  def filter_servers_minutes_old(servers, minutes_old) do
    create_cutoff = Timex.now |> Timex.shift(minutes: -minutes_old)
    Enum.filter(servers, fn(server) ->
      DateTime.compare(create_cutoff, server.create_time) == :gt
    end)
  end

end

