defmodule DynamicServerManager.Example do

  @moduledoc """
  Examle usage for creating/destroying a server, and hooking a DNS record
  to it.
  """

  alias DynamicServerManager.Server
  alias DynamicServerManager.Dns
  require Logger
  use Tesla, only: [:get, :post]

  @timer_seconds 2
  @timer_dns_seconds 5
  @timer_status_attempts_max 180
  @timer_dns_attempts_max 10
  @logger_metadata []
  @deployment_images Application.get_env(:dynamic_server_manager, :deployment_images)

  plug Tesla.Middleware.Tuples, rescue_errors: :all
  plug Tesla.Middleware.JSON
  if Application.get_env(:dynamic_server_manager, :debug_http) do
    plug Tesla.Middleware.DebugLogger
  end

  def create(server_provider_label \\ :dummy, location \\ :one, dns_provider_label \\ :dummy, domain \\ "example.com", server \\ :small) do
    Process.put(:start_time, DateTime.utc_now())
    provider = Server.get_module(server_provider_label)
    hostname = Server.make_hostname()
    fqdn = make_fqdn(hostname, domain)
    overrides = get_provider_overrides(server_provider_label, location, fqdn)
    with {:ok, specs} <- provider.config(location, server, overrides),
         {:ok, server_metadata} <- provider.create_from_snapshot(specs),
         :ok <- create_loop_status(provider, :unavailable, server_metadata),
         {:ok, info} <- provider.info(server_metadata),
         public_ip_v4 = info.public_ip_v4,
         external_ip_v4 = Map.get(info, :external_ip_v4),
         ip = (if (external_ip_v4), do: external_ip_v4, else: public_ip_v4),
         {:ok, dns_metadata} <- create_dns_record(dns_provider_label, domain, hostname, ip)
    do
      calculate_startup_time()
      {server_metadata, dns_metadata}
    else
      error ->
        error
    end
  end

  def destroy(server_metadata, dns_metadata) do
    server_provider = Server.get_module(server_metadata.provider)
    server_destroyed = server_provider.destroy(server_metadata)
    ipv4_record_deleted = delete_dns_record(dns_metadata)
    {server_destroyed, ipv4_record_deleted}
  end

  defp get_provider_overrides(server_provider_label, location, fqdn) do
    overrides = %{
      fqdn: fqdn,
    }
    Map.merge(overrides, @deployment_images[server_provider_label][location])
  end

  defp create_dns_record(dns_provider_label, domain, hostname, ip) do
    provider = Dns.get_module(dns_provider_label)
    create_dns_record(provider, domain, hostname, ip, 1)
  end

  defp create_dns_record(provider, domain, hostname, ip, count) do
    Logger.info fn -> {"Creating DNS record for #{hostname}.#{domain} (#{ip}) using provider #{provider}, attempt ##{count}", @logger_metadata} end
    ipv4_record_created = provider.create_ipv4_record(domain, hostname, ip)
    case ipv4_record_created do
      :ok ->
         Logger.info fn -> {"DNS record for #{hostname}.#{domain} (#{ip}), created", @logger_metadata} end
         {:ok, %{
           provider: provider,
           domain: domain,
           hostname: hostname,
         }}
      error ->
        error_msg = case error do
          {:error, error} ->
            {:error, error}
          error ->
            {:error, error}
        end
        if count >= @timer_dns_attempts_max do
          Logger.error fn -> {"Creating DNS record for #{hostname}.#{domain} (#{ip}) using provider #{provider}, failed, max attempts #{@timer_dns_attempts_max} exceeded", @logger_metadata} end
          {:error, :max_attempts_exceeded}
        else
          Logger.warn fn -> {"Creating DNS record for #{hostname}.#{domain} (#{ip}) failed: " <> inspect(error_msg), @logger_metadata} end
          :timer.sleep(:timer.seconds(@timer_dns_seconds))
          create_dns_record(provider, domain, hostname, ip, count + 1)
        end
    end
  end

  defp delete_dns_record(metadata) do
    delete_dns_record(metadata.provider, metadata.domain, metadata.hostname, 1)
  end

  defp delete_dns_record(provider, domain, hostname, count) do
    Logger.info fn -> {"Deleting DNS record for #{hostname}.#{domain} using provider #{provider}, attempt ##{count}", @logger_metadata} end
    ipv4_record_deleted = provider.delete_ipv4_record(domain, hostname)
    case ipv4_record_deleted do
      :ok ->
         Logger.info fn -> {"DNS record for #{hostname}.#{domain} deleted", @logger_metadata} end
         :ok
      error ->
        error_msg = case error do
          {:error, error} ->
            {:error, error}
          error ->
            {:error, error}
        end
        if count >= @timer_dns_attempts_max do
          Logger.error fn -> {"Deleting DNS record for #{hostname}.#{domain} using provider #{provider}, failed, max attempts #{@timer_dns_attempts_max} exceeded", @logger_metadata} end
          {:error, :max_attempts_exceeded}
        else
          Logger.warn fn -> {"Deleting DNS record for #{hostname}.#{domain} failed: " <> inspect(error_msg), @logger_metadata} end
          :timer.sleep(:timer.seconds(@timer_dns_seconds))
          delete_dns_record(provider, domain, hostname, count + 1)
        end
    end
  end

  defp calculate_startup_time() do
    start_time = Process.get(:start_time)
    end_time = DateTime.utc_now()
    total_seconds = DateTime.diff(end_time, start_time)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    minutes_label = if (minutes == 1), do: "minute", else: "minutes"
    seconds_label = if (seconds == 1), do: "second", else: "seconds"
    Logger.info fn -> {"Server creation time: #{minutes} #{minutes_label}, #{seconds} #{seconds_label}", @logger_metadata} end
  end

  defp create_loop_status(provider, status, metadata) do
    create_loop_status(provider, status, metadata, 1)
  end

  defp create_loop_status(_provider, {:error, error}, _metadata, _count) do
    {:error, error}
  end

  defp create_loop_status(_provider, :running, metadata, _count) do
    Logger.info fn -> {"Server #{inspect(metadata)} is running", @logger_metadata} end
    :ok
  end

  defp create_loop_status(provider, status, metadata, count) do
    Logger.debug fn -> {"Checking server #{inspect(metadata)} status is #{status}, waiting on status running, attempt ##{count}", @logger_metadata} end
    :timer.sleep(:timer.seconds(@timer_seconds))
    next_status = provider.status(metadata)
    if count > @timer_status_attempts_max do
      {:error, "Creating server max status changed attempts #{@timer_status_attempts_max} exceeded"}
    else
      create_loop_status(provider, next_status, metadata, count + 1)
    end
  end

  defp make_fqdn(hostname, domain) do
    hostname <> "." <> domain
  end

end
