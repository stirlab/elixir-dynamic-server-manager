defmodule DynamicServerManager.Dns.Aws do
  @behaviour DynamicServerManager.Dns

  require ExAws
  alias ExAws.Route53
  require Logger

  @logger_metadata [plugin: :dns_aws]

  def up() do
    result = list_zones()
    case result do
      {:ok, %{status_code: 200}} ->
        true
      error ->
        Logger.error fn -> {"Error getting provider up value: " <> inspect(error), @logger_metadata} end
        false
    end
  end

  def get_record(zone_name, hostname) do
    zone_id = get_zone_id(zone_name)
    result = Route53.list_record_sets(zone_id, [name: make_fqdn(zone_name, hostname)]) |> ExAws.request
    case result do
      {:ok, ret} ->
        record = ret.body.record_sets |> Enum.at(0)
        if record do
          data = %{
            type: record.type |> String.downcase() |> String.to_atom(),
            ttl: record.ttl,
            ip: record.values |> Enum.at(0),
          }
          Logger.debug fn -> {"Got record for zone #{zone_name}, host #{hostname}: " <> inspect(data), @logger_metadata} end
          {:ok, data}
        else
          Logger.error fn -> {"No record sets for zone #{zone_name}, host #{hostname}", @logger_metadata} end
          {:error, "No record sets"}
        end
      error ->
        Logger.error fn -> {"Error getting record for zone #{zone_name}, host #{hostname}: " <> inspect(error), @logger_metadata} end
        {:error, error}
    end
  end

  def create_ipv4_record(zone_name, hostname, ip) do
    Logger.debug fn -> {"Creating record #{hostname} (#{ip}) for zone #{zone_name}", @logger_metadata} end
    result = create_record(zone_name, hostname, ip)
    handle_response(:create_ipv4, result)
  end

  def delete_ipv4_record(zone_name, hostname) do
    Logger.debug fn -> {"Deleting record #{hostname} for zone #{zone_name}", @logger_metadata} end
    result = delete_record(zone_name, hostname)
    handle_response(:delete_ipv4, result)
  end

  def list_zones() do
    Route53.list_hosted_zones() |> ExAws.request
  end

  def list_records(zone_name) do
    zone_id = get_zone_id(zone_name)
    Route53.list_record_sets(zone_id) |> ExAws.request
  end

  defp handle_response(action, result) do
    case result do
      {:ok, :noop} ->
        Logger.debug fn -> {"Noop for #{action}", @logger_metadata} end
        :ok
      {:ok, %{body: %{change_info: %{id: _record_id}}}} ->
        Logger.debug fn -> {"Response success for #{action}", @logger_metadata} end
        :ok
      {:error, error} ->
        Logger.error fn -> {"Response error for #{action}: " <> inspect(error), @logger_metadata} end
        {:error, error}
      error ->
        Logger.error fn -> {"Response error for #{action}: " <> inspect(error), @logger_metadata} end
        {:error, error}
    end
  end

  defp create_record(zone_name, hostname, ipv4, opts \\ nil) do
    zone_config_opts = opts || default_zone_config_opts()
    opts = [
      action: :upsert,
    ] ++ zone_config_opts ++ [
      name: make_fqdn(zone_name, hostname),
      records: [
        ipv4,
      ]
    ]
    zone_id = get_zone_id(zone_name)
    Route53.change_record_sets(zone_id, opts) |> ExAws.request
  end

  defp delete_record(zone_name, hostname) do
    result = get_record(zone_name, hostname)
    case result do
      {:ok, record} ->
        delete_record(zone_name, hostname, record.ip)
      {:error, _error} ->
        {:ok, :noop}
    end
  end

  defp delete_record(zone_name, hostname, records, opts \\ nil) do
    record_list = List.wrap(records)
    zone_config_opts = opts || default_zone_config_opts()
    opts = [
      action: :delete,
    ] ++ zone_config_opts ++ [
      name: make_fqdn(zone_name, hostname),
      records: record_list,
    ]
    zone_id = get_zone_id(zone_name)
    Route53.change_record_sets(zone_id, opts) |> ExAws.request
  end

  defp get_zone_id(zone_name) do
    Application.fetch_env!(:dynamic_server_manager, :aws_dns_zones) |> Map.fetch!(zone_name)
  end

  defp make_fqdn(zone_name, hostname) do
    hostname <> "." <> zone_name
  end

  defp default_zone_config_opts() do
    [
      ttl: Application.get_env(:dynamic_server_manager, :dns_ttl, 86400),
      type: :a,
    ]
  end

end

