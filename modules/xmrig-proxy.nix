{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.xmrig-proxy;
in
{
  options.services.xmrig-proxy = {
    enable = lib.mkEnableOption "XMRig Stratum proxy for CPU mining";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.xmrig-proxy;
      description = "XMRig proxy package to use";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "xmrig-proxy";
      description = "User account to run xmrig-proxy";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "xmrig-proxy";
      description = "Group account to run xmrig-proxy";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/xmrig-proxy";
      description = "Data directory for xmrig-proxy";
    };

    config = lib.mkOption {
      type = lib.types.str;
      description = "xmrig-proxy configuration (JSON format)";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open firewall ports for xmrig-proxy";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 3333;
      description = "Stratum port to listen on";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "API port for monitoring";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing API token (overrides 'token' option)";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      inherit (cfg) group;
      isSystemUser = true;
      description = "XMRig proxy service user";
    };

    users.groups.${cfg.group} = { };

    environment.etc."xmrig-proxy/config.json".text =
      if cfg.tokenFile == null then
        cfg.config
      else
        builtins.replaceStrings [ "\"token\"" ] [ "TOKEN_FROM_FILE" ] cfg.config;

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = lib.mkOptionDefault [ cfg.apiPort ];
      allowedUDPPorts = [ cfg.listenPort ];
      interfaces."tailscale0".allowedTCPPorts = [ cfg.apiPort ];
    };


    systemd = {
      tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
        "d /run/xmrig-proxy 0750 ${cfg.user} ${cfg.group} -"
      ];

      services.xmrig-proxy = {
        description = "XMRig Stratum Proxy for CPU Mining";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "agenix-rekey.service"
          "systemd-tmpfiles-setup.service"
        ];

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;

          WorkingDirectory = cfg.dataDir;

          ExecStart = "${cfg.package}/bin/xmrig-proxy --config /etc/xmrig-proxy/config.json --no-color";

          Restart = "on-failure";
          RestartSec = "10s";

          PrivateTmp = lib.mkIf (cfg.tokenFile == null) true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [
            cfg.dataDir
            "/run/xmrig-proxy"
          ];

          RuntimeDirectory = "xmrig-proxy";
          RuntimeDirectoryMode = "0750";

          MemoryLimit = "512M";
          CPUQuota = "200%";
        };

        serviceConfig.ExecStop = "${pkgs.coreutils}/bin/kill -SIGTERM $MAINPID";
      };

      services.xmrig-proxy-preStart =
        lib.mkIf (cfg.tokenFile != null) {
          description = "Inject API token into xmrig-proxy config";
          wantedBy = [ "xmrig-proxy.service" ];
          before = [ "xmrig-proxy.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "xmrig-proxy-inject-token" ''
              #!${pkgs.bash}/bin/bash
              set -euo pipefail

              TOKEN_FILE="${cfg.tokenFile}"
              CONFIG_FILE="/etc/xmrig-proxy/config.json"
              RUNTIME_CONFIG="/run/xmrig-proxy/config.json"

              if [ ! -f "$TOKEN_FILE" ]; then
                echo "[xmrig-proxy] Waiting for token file: $TOKEN_FILE"
                for i in {1..30}; do
                  if [ -f "$TOKEN_FILE" ]; then
                    break
                  fi
                  sleep 1
                done
                if [ ! -f "$TOKEN_FILE" ]; then
                  echo "[xmrig-proxy] ERROR: Token file not found after 30 seconds"
                  exit 1
                fi
              fi

              TOKEN=$(${pkgs.coreutils}/bin/cat "$TOKEN_FILE")
              mkdir -p /run/xmrig-proxy
              ${pkgs.jq}/bin/jq --arg token "$TOKEN" '.api.token = $token' "$CONFIG_FILE" > "$RUNTIME_CONFIG"
              chmod 640 "$RUNTIME_CONFIG"
              chown ${cfg.user}:${cfg.group} "$RUNTIME_CONFIG"

              echo "[xmrig-proxy] Token injected successfully"
            '';
          };
        }
        // lib.optionalAttrs (cfg.tokenFile != null) {
          serviceConfig.ExecStart = lib.mkForce (
            pkgs.writeShellScript "xmrig-proxy" ''
              ${lib.getExe cfg.package} --config /run/xmrig-proxy/config.json --no-color
            ''
          );
        };
    };
  };
}
