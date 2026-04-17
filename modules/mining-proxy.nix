{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.mining-proxy;
in {
  options.services.mining-proxy = {
    enable = lib.mkEnableOption "Universal mining stratum proxy with failover";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3Packages.buildPythonApplication rec {
        pname = "mining-proxy";
        version = "unstable-2024-03-10";

        src = pkgs.fetchFromGitHub {
          owner = "siv2k";
          repo = "mining-proxy";
          rev = "master";
          sha256 = lib.fakeSha256;
        };

        propagatedBuildInputs = with pkgs.python3Packages; [
          twisted
          autobahn
          requests
        ];

        doCheck = false;

        meta = with lib; {
          description = "Multi-pool stratum mining proxy with failover";
          homepage = "https://github.com/siv2k/mining-proxy";
          license = licenses.gpl3;
          platforms = platforms.unix;
          mainProgram = "mining-proxy";
        };
      };
      description = "Mining proxy package";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "mining-proxy";
      description = "User account to run mining-proxy";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "mining-proxy";
      description = "Group account to run mining-proxy";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mining-proxy";
      description = "Data directory for mining-proxy";
    };

    pools = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Pool name";
          };
          url = lib.mkOption {
            type = lib.types.str;
            description = "Pool stratum URL (e.g., stratums+tcp://pool:3333)";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 1;
            description = "Pool priority (1 = highest)";
          };
          weight = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "Pool weight for load balancing";
          };
        };
      });
      description = "List of mining pools with failover configuration";
    };

    workers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          id = lib.mkOption {
            type = lib.types.str;
            description = "Worker ID (e.g., zephyr-cpu)";
          };
          password = lib.mkOption {
            type = lib.types.str;
            default = "x";
            description = "Worker password";
          };
        };
      });
      description = "List of worker configurations";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 3334;
      description = "Stratum port to listen on (use different port than xmrig-proxy)";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "API port for monitoring";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open firewall ports for mining-proxy";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      inherit (cfg) group;
      isSystemUser = true;
      description = "Mining proxy service user";
    };

    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    environment.etc."mining-proxy/config.json".text = builtins.toJSON {
      pools =
        builtins.map (pool: {
          inherit (pool) name;
          inherit (pool) url;
          inherit (pool) priority;
          inherit (pool) weight;
          tls = lib.hasPrefix "ssl" pool.url;
        })
        cfg.pools;

      workers =
        builtins.map (worker: {
          inherit (worker) id;
          inherit (worker) password;
        })
        cfg.workers;

      api = {
        port = cfg.apiPort;
        restricted = true;
        token = "your-api-token-here";
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = lib.mkOptionDefault [cfg.listenPort];
      allowedUDPPorts = lib.mkOptionDefault [cfg.listenPort];
    };

    systemd.services.mining-proxy = {
      description = "Universal Mining Stratum Proxy with Failover";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        WorkingDirectory = cfg.dataDir;

        ExecStart = "${cfg.package}/bin/mining-proxy --config /etc/mining-proxy/config.json";
        ExecStop = "${pkgs.coreutils}/bin/kill -SIGTERM $MAINPID";

        Restart = "on-failure";
        RestartSec = "10s";

        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [cfg.dataDir];

        MemoryLimit = "1G";
        CPUQuota = "300%";
      };
    };
  };
}
