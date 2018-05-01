defmodule DynamicServerManager.Mixfile do
  use Mix.Project

  def project do
    [
      app: :dynamic_server_manager,
      version: "0.0.5",
      elixir: "~> 1.6",
      start_permanent: Mix.env == :prod,
      package: package(),
      description: description(),
      deps: deps(),
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DynamicServerManager.Application, %{}}
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "mix.exs",
        "README*",
        "LICENSE*",
      ],
      maintainers: [
        "Chad Phillips",
      ],
      licenses: [
        "MIT",
      ],
      links: %{
        "GitHub" => "https://github.com/stirlab/elixir-dynamic-server-manager",
        "Home" => "http://stirlab.net",
      },
    ]
  end

  defp description do
    """
    Simple, high-level API for managing cloud servers across multiple
    providers.

    This doesn't try to be everything, but instead provides two basic
    behaviours (server and DNS), for which additional providers can be added.
    """
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:ex_aws, "~> 2.0"},
      {:ex_aws_ec2, "~> 2.0"},
      {:ex_aws_route53, "~> 2.0"},
      {:cloudsigma_api_wrapper, "~> 0.1"},
      {:digitalocean_api_wrapper, "~> 0.1"},
      {:profitbricks_api_wrapper, "~> 0.1"},
      {:hackney, "~> 1.12"},
      {:sweet_xml, "~> 0.6"},
      {:poison, "~> 3.1.0"},
      {:uuid, "~> 1.1"},
      {:timex, "~> 3.2"},
    ]
  end

end
