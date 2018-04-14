use Mix.Config

#
# Key-module mappings. Required for now.
# TODO: This should probably be done in some kind of registry system?
#

alias DynamicServerManager.Server
config :dynamic_server_manager, server_module_map: %{
  aws: Server.Aws,
  cloudsigma: Server.CloudSigma,
  digitalocean: Server.DigitalOcean,
  profitbricks: Server.ProfitBricks,
  dummy: Server.Dummy,
}

alias DynamicServerManager.Dns
config :dynamic_server_manager, dns_module_map: %{
  aws: Dns.Aws,
  dummy: Dns.Dummy,
}


#
# Plugin config.
#

config :ex_aws,
  access_key_id: "",
  secret_access_key: ""

config :cloudsigma_api_wrapper, api_endpoint_location: "zrh"
config :cloudsigma_api_wrapper,
  user_email: "",
  password: ""

config :digitalocean_api_wrapper, access_token: ""

config :profitbricks_api_wrapper,
  username: "",
  password: ""


#
# DNS-specific plugin config.
#

config :dynamic_server_manager, aws_dns_zones: %{
  "example.com" => "zone ID from the plugin's list_zones/1",
}

#
# Server-specific plugin config.
#

dummy_defaults = %{
  size: "20GB",
}
config :dynamic_server_manager, :server_plugin_dummy,
  locations: %{
    one: %{
      location: "location-one",
    },
    two: %{
      location: "location-two",
    },
  },
  servers: %{
    test: Map.merge(dummy_defaults, %{
      cores: 1,
      ram: 1,
    }),
    small: Map.merge(dummy_defaults, %{
      cores: 3,
      ram: 3,
    }),
    medium: Map.merge(dummy_defaults, %{
      cores: 5,
      ram: 3,
    }),
    large: Map.merge(dummy_defaults, %{
      cores: 10,
      ram: 4,
    }),
  }

config :dynamic_server_manager, aws_key_name: "instance-key-pair-name"
config :dynamic_server_manager, :server_plugin_aws,
  locations: %{
    virginia: %{
      region: "us-east-1",
    },
    ohio: %{
      region: "us-east-2",
    },
  },
  servers: %{
    test: %{
      instance_type: "t2.micro",
    },
    small: %{
      instance_type: "c5.xlarge",
    },
    medium: %{
      instance_type: "c5.2xlarge",
    },
    large: %{
      instance_type: "c5.4xlarge",
    },
  }

cloudsigma_defaults = %{
  vnc_password: "supersecret",
  tags: ["sometag"],
}
config :dynamic_server_manager, :server_plugin_cloudsigma,
  locations: %{
    mia: %{
      location: "mia",
    },
    wdc: %{
      location: "wdc",
    },
  },
  servers: %{
    test: Map.merge(cloudsigma_defaults, %{
      cpu: 2000,
      mem: 2147483648,
    }),
    small: Map.merge(cloudsigma_defaults, %{
      cpu: 11200,
      mem: 2147483648,
    }),
    medium: Map.merge(cloudsigma_defaults, %{
      cpu: 22400,
      mem: 3221225472,
    }),
    large: Map.merge(cloudsigma_defaults, %{
      cpu: 28000,
      mem: 4294967296,
      enable_numa: true,
    }),
  }

# This allows bypassing DO's requirement to reset the root password on first
# login to a new instance.
digitalocean_defaults = %{
  user_data: "#cloud-config\n\nruncmd:\n  - echo root:someotherpassword | chpasswd",
}
config :dynamic_server_manager, :server_plugin_digitalocean,
  locations: %{
    # New York 3.
    nyc3: %{
      region: "nyc3",
    },
    # Toronto 1.
    tor1: %{
      region: "tor1",
    },
  },
  servers: %{
    test: Map.merge(digitalocean_defaults, %{
      size: "512mb",
    }),
    small: Map.merge(digitalocean_defaults, %{
      size: "c-8",
    }),
    medium: Map.merge(digitalocean_defaults, %{
      size: "c-16",
    }),
    large: Map.merge(digitalocean_defaults, %{
      size: "c-32",
    }),
  }

profitbricks_server_defaults = %{
  cpuFamily: "INTEL_XEON",
  size: 10,
}
config :dynamic_server_manager, :server_plugin_profitbricks,
  locations: %{
    # New Jersey.
    ewr: %{
      region_location: "us/ewr",
      base_datacenter: "base-datacenter-id-1",
    },
    # Las Vegas.
    las: %{
      region_location: "us/las",
      base_datacenter: "base-datacenter-id-2",
    },
  },
  servers: %{
    test: Map.merge(profitbricks_server_defaults, %{
      cores: 1,
      ram: 2048,
    }),
    small: Map.merge(profitbricks_server_defaults, %{
      cores: 2,
      ram: 2048,
    }),
    medium: Map.merge(profitbricks_server_defaults, %{
      cores: 3,
      ram: 3072,
    }),
    large: Map.merge(profitbricks_server_defaults, %{
      cores: 5,
      ram: 4096,
    }),
  }

# Example deployment image map.
config :dynamic_server_manager, :deployment_images,
  %{
    :aws => %{
      virginia: %{
        ami: "ami-id1",
      },
      ohio: %{
        ami: "ami-id1",
      },
    },
    :cloudsigma => %{
      mia: %{
        uuid: "server-uuid-1",
      },
      wdc: %{
        uuid: "server-uuid-2",
      },
    },
    :digitalocean => %{
      nyc3: %{
        image: "image-id-1",
      },
      tor1: %{
        image: "image-id-2",
      },
    },
    :profitbricks => %{
      ewr: %{
        image: "image-id-1",
      },
      las: %{
        image: "image-id-2",
      },
    },
    :dummy => %{
      one: %{
        image: "image-id-1",
      },
      two: %{
        image: "image-id-2",
      },
    },
  }
