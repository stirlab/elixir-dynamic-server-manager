defmodule DynamicServerManager.Server.Aws do

  @behaviour DynamicServerManager.Server

  alias DynamicServerManager.Server

  require ExAws
  alias ExAws.EC2
  import SweetXml

  require Logger

  @plugin :server_plugin_aws
  @logger_metadata [plugin: :server_aws]

  def up(location) when is_atom(location) do
    region = Server.get_location(@plugin, location).region
    xml = EC2.describe_availability_zones([filters: [{"region-name", region}, {:state, "available"}]]) |> ExAws.request(region: region)
    case xml do
      {:ok, ret} ->
        up = parse_availability_zones_data(ret.body)
        Logger.debug fn -> {"Got provider up value for #{location}: #{up}", @logger_metadata} end
        up
      error ->
        Logger.error fn -> {"Error getting provider up value for #{location}: " <> inspect(error), @logger_metadata} end
        false
    end
  end

  def config(location, server, overrides \\ %{}) do
    Server.build_config(@plugin, location, server, overrides)
  end

  def create_from_snapshot(specs) do
    aws_key_name = Application.fetch_env!(:dynamic_server_manager, :aws_key_name)
    opts = [
      instance_type: specs.instance_type,
      key_name: aws_key_name,
      tag_specifications: [
        {:instance, [{"Name", specs.fqdn}]},
      ],
    ]
    Logger.debug fn -> {"Creating server from AMI #{specs.ami} in region #{specs.location.region}, opts: " <> inspect(opts), @logger_metadata} end
    server_created = run_instance(specs.location.region, specs.ami, opts)
    case server_created do
      {:ok, server_id} ->
        Logger.info fn -> {"Created server #{server_id} from from AMI #{specs.ami} in region #{specs.location.region}", @logger_metadata} end
        {:ok, %{
          provider: :aws,
          location: specs.location,
          server: server_id,
        }}
      error ->
        error
    end
  end

  def status(%{server: id, location: %{region: region}}) do
    xml = EC2.describe_instance_status(%{:instance_ids => [id], include_all_instances: true}) |> ExAws.request(region: region)
    case xml do
      { :ok, ret } ->
        parse_instance_status_data(ret.body)
      error ->
        message = "Error getting status for server #{id}"
        error_handler(error, message, id)
    end
  end

  def info(%{server: id, location: %{region: region}}) do
    Logger.debug fn -> {"Getting info for server #{id}", @logger_metadata} end
    xml = EC2.describe_instances(%{:instance_ids => [id]}) |> ExAws.request(region: region)
    case xml do
      { :ok, ret } ->
        info = parse_instance_data(ret.body)
        Logger.debug fn -> {"Got info for server #{id}: " <> inspect(info), @logger_metadata} end
        {:ok, info}
      error ->
        message = "Error getting server #{id} info"
        error_handler(error, message, id)
    end
  end

  def destroy(%{server: id, location: %{region: region}}) do
    Logger.debug fn -> {"Destroying server #{id} in region #{region}", @logger_metadata} end
    xml = EC2.terminate_instances([id]) |> ExAws.request(region: region)
    case xml do
      { :ok, _ret } ->
        Logger.info fn -> {"Destroyed server #{id}", @logger_metadata} end
        :ok
      error ->
        message = "Error destroying server #{id}"
        error_handler(error, message, id)
    end
  end

  def list_servers(location, minutes_old \\ nil) when is_atom(location) and (is_nil(minutes_old) or is_integer(minutes_old) and minutes_old > 0) do
    Logger.debug fn -> {"Listing servers for location #{location}", @logger_metadata} end
    # TODO: Refactor to get paged results.
    xml = EC2.describe_instances([filters: [{"instance-state-name", "running"}], max_results: 1000]) |> ExAws.request(region: Server.get_location(@plugin, location).region)
    case xml do
      { :ok, ret } ->
        servers = parse_server_list_data(ret.body)
        Logger.debug fn -> {"Got server list for location #{location}", @logger_metadata} end
        {:ok, Server.filter_servers_minutes_old(servers, minutes_old)}
      error ->
        Logger.error fn -> {"Error listing servers for location #{location}: " <> inspect(error), @logger_metadata} end
        {:error, error}
    end
  end

  defp run_instance(region, ami, opts) do
    xml = EC2.run_instances(ami, 1, 1, opts) |> ExAws.request(region: region)
    case xml do
      { :ok, ret } ->
        server_id = parse_create_instance_data(ret.body)
        Logger.info fn -> {"Created server #{server_id} from AMI #{ami}", @logger_metadata} end
        {:ok, server_id}
      error ->
        message = "Error creating server from AMI #{ami}"
        error_handler(error, message)
    end
  end

  defp check_server_not_found_error(data) do
    has_errors = data |> xpath(~x"//Response/Errors")
    if has_errors do
      error_code = data |> xpath(~x"//Response/Errors/descendant::Error[1]/Code/text()") |> to_string()
      error_code == "InvalidInstanceID.NotFound"
    else
      false
    end
  end

  defp server_not_found(id) do
    Logger.error fn -> {"Server #{id} not found", @logger_metadata} end
    {:error, :not_found}
  end

  defp error_handler(response, message) do
    Logger.error fn -> {message <> ": " <> inspect(response), @logger_metadata} end
    {:error, response}
  end

  defp error_handler(response, message, id) do
    case response do
      {:error, {:http_error, _code, %{body: body}}} ->
        if check_server_not_found_error(body) do
          server_not_found(id)
        else
          Logger.error fn -> {message <> ": " <> inspect(response), @logger_metadata} end
          {:error, response}
        end
      _error ->
        Logger.error fn -> {message <> ": " <> inspect(response), @logger_metadata} end
        {:error, response}
    end
  end

  defp parse_availability_zones_data(data) do
    xpath(data, ~x"//availabilityZoneInfo/descendant::item") != nil
  end

  defp parse_create_instance_data(data) do
    data |> xpath(
      ~x"//instancesSet/descendant::item[1]/instanceId/text()"
    ) |> to_string
  end

  defp parse_instance_data(data) do
    raw_data = data |> xpath(
      ~x"//reservationSet/descendant::item[1]/instancesSet/descendant::item[1]",
      instanceId: ~x"./instanceId/text()",
      privateIpAddress: ~x"./privateIpAddress/text()",
      ipAddress: ~x"./ipAddress/text()",
      tags: [
        ~x"./tagSet/item"l,
        key: ~x"./key/text()",
        value: ~x"./value/text()",
      ]
    )
    %{
      external_ip_v4: to_string(raw_data[:ipAddress]),
      public_ip_v4: to_string(raw_data[:privateIpAddress]),
      # Not returning tags right now.
    }
  end

  defp parse_instance_status_data(data) do
    # It's possible the instance status data may not be populated yet, check
    # first and assume a starting state if so.
    if xpath(data, ~x"//instanceStatusSet/descendant::item") == nil do
      :starting
    else
      raw_data = data |> xpath(
        ~x"//instanceStatusSet/descendant::item[1]",
        instanceState: ~x"./instanceState/name/text()",
        systemStatus: ~x"./systemStatus/status/text()",
        instanceStatus: ~x"./instanceStatus/status/text()"
      )
      data = %{
        instance_state: to_string(raw_data[:instanceState]),
        instance_status: to_string(raw_data[:instanceStatus]),
        system_status: to_string(raw_data[:systemStatus]),
      }
      case data.instance_state do
        "pending" ->
          :starting
        "running" ->
          if data.instance_status == "ok" and data.system_status == "ok" do
            :running
          else
            if data.instance_status == "impaired" or data.system_status == "impaired" do
              {:error, :impaired}
            else
              :starting
            end
          end
        "shutting-down" ->
          :destroying
        "stopping" ->
          :destroying
        "stopped" ->
          :destroying
        "terminated" ->
          :destroyed
      end
    end
  end

  defp parse_server_list_data(data) do
    raw_data = data |> xpath(
      ~x"//reservationSet/descendant::item[1]/instancesSet/item"l,
      instanceId: ~x"./instanceId/text()",
      launchTime: ~x"./launchTime/text()"
    )
    Enum.map(raw_data, fn(server) ->
      %{
        server: to_string(server[:instanceId]),
        create_time: Server.parse_datestring(to_string(server[:launchTime])),
      }
    end)
  end

end
