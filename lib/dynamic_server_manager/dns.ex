defmodule DynamicServerManager.Dns do
  @type record_type :: [:a | :aaaa | :cname | :mx | :naptr | :ns | :ptr | :soa | :spf | :srv | :txt]
  @type record :: %{type: record_type, ttl: Integer.t, ip: String.t}
  @callback up() :: boolean()
  @callback get_record(zone_name :: String.t, hostname :: String.t) :: {:ok, record} | {:error, String.t}
  @callback create_ipv4_record(zone_name :: String.t, hostname :: String.t, ip :: String.t) :: :ok | {:error, String.t}
  @callback delete_ipv4_record(zone_name :: String.t, hostname :: String.t) :: :ok | {:error, String.t}

  def get_module(provider) when is_atom(provider) do
    Application.fetch_env!(:dynamic_server_manager, :dns_module_map) |> Map.fetch!(provider)
  end

  def up(provider_label) do
    provider = get_module(provider_label)
    provider.up()
  end

  def get_record(provider_label, zone_name, hostname) do
    provider = get_module(provider_label)
    provider.get_record(zone_name, hostname)
  end

  def create_ipv4_record(provider_label, zone_name, hostname, ip) do
    provider = get_module(provider_label)
    provider.create_ipv4_record(zone_name, hostname, ip)
  end

  def delete_ipv4_record(provider_label, zone_name, hostname) do
    provider = get_module(provider_label)
    provider.delete_ipv4_record(zone_name, hostname)
  end

end

