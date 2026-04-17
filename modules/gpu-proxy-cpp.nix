{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.gpu-proxy-cpp;

  gpu-proxy-cpp-package = pkgs.stdenv.mkDerivation rec {
    pname = "gpu-proxy-cpp";
    version = "2.0.0";

    src = ./gpu-proxy-cpp;

    nativeBuildInputs = with pkgs; [cmake pkg-config];
    buildInputs = with pkgs; [openssl nlohmann_json];

    cmakeFlags = ["-DCMAKE_BUILD_TYPE=Release"];

    preConfigure = ''
      export NIX_CFLAGS_COMPILE="-I${pkgs.nlohmann_json}/include/nlohmann $NIX_CFLAGS_COMPILE"
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp gpu-proxy $out/bin/
    '';
  };

  configJson = pkgs.writeText "gpu-proxy-config.json" (
    builtins.toJSON {
      settings = {
        listen_port = cfg.listenPort;
        api_port = cfg.apiPort;
        log_level = cfg.logLevel;
      };
      inherit (cfg) pools;
      inherit (cfg) workers;
    }
  );
in {
  options.services.gpu-proxy-cpp = {
    enable = lib.mkEnableOption "C++ GPU mining proxy for CR29/Kryptex";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 3334;
      description = "Port to listen for miner connections";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8083;
      description = "Port for HTTP API (stats, workers, etc.)";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "INFO";
      description = "Log level (DEBUG, INFO, WARNING, ERROR)";
    };

    pools = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Pool name for identification";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "Pool URL (host:port)";
            };
            wallet = lib.mkOption {
              type = lib.types.str;
              description = "Mining wallet address";
            };
            password = lib.mkOption {
              type = lib.types.str;
              default = "x";
              description = "Mining password (usually 'x')";
            };
            tls = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Use TLS for pool connection";
            };
            priority = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Pool priority (lower = higher priority)";
            };
          };
        }
      );
      description = "List of mining pools with failover";
    };

    workers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Worker ID to allow in whitelist";
            };
            password = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Worker password (unused for now)";
            };
          };
        }
      );
      default = [];
      description = "Worker whitelist (empty = allow all)";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.gpu-proxy-cpp = {
      description = "C++ GPU Mining Proxy for CR29";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        ExecStart = "${gpu-proxy-cpp-package}/bin/gpu-proxy --config ${configJson}";
        Restart = "on-failure";
        RestartSec = "5s";
        DynamicUser = true;
        ReadOnlyPaths = [configJson];
        ReadWritePaths = [];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        AmbientCapabilities = [];
        CapabilityBoundingSet = "";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkOptionDefault [cfg.listenPort];
  };
}
