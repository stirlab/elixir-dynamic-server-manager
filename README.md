# DynamicServerManager

Simple, high-level API for managing cloud servers across multiple
providers from within [Elixir](http://elixir-lang.github.io).

This doesn't try to be everything, but instead provides two basic
behaviours, for which additional providers can be added:

 * Server:
   * Create based on snapshot
   * Destroy
   * Query for basic information

 * DNS:
   * Create/destroy A records for configured domains


## Installation

First, add to your `mix.exs` dependencies:

```elixir
def deps do
  [{:dynamic_server_manager, "~> 0.0.1"}]
end
```
Then, update your dependencies:

```sh
$ mix deps.get
```

## Configuration

See the [sample configuration](config/config.sample.exs)


## Usage

See the [example usage](lib/example.ex)


## Currently supported providers

 * Server:
   * [AWS EC2](https://aws.amazon.com/ec2)
   * [CloudSigma](https://www.cloudsigma.com)
   * [DigitalOcean](https://www.digitalocean.com)
   * [ProfitBricks](https://www.profitbricks.com)

 * DNS:
   * [AWS Route53](https://aws.amazon.com/route53)


## Writing new providers

They are based on the behaviours as defined in the following modules:

 * Server: DynamicServerManager.Server
 * DNS: DynamicServerManager.Dns

Hopefully between that and referencing the existing plugins you'll get the
idea.


### TODO

 * Better documentation (maybe, someday...)
 * Better plugin label/module mapping, possibly via registration
