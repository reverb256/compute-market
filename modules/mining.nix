{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.mining;
  hostname = config.networking.hostName;
  defaultWallet = "krxXVNVMM7.${hostname}";
  lolminerHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    ProtectHostname = true;
    RestrictRealtime = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadOnlyPaths = "/";
    ReadWritePaths = [
      "/var/lib/mining"
      "/var/log/mining"
    ];
    CapabilityBoundingSet = "CAP_SYS_NICE";
    AmbientCapabilities = "CAP_SYS_NICE";
  };
  nvidiaGpuPowerLimitScript = pkgs.writeShellScript "nvidia-gpu-power-limit" ''
    PATH=/run/current-system/sw/bin:$PATH
    echo "Setting NVIDIA GPU power limits..."
    nvidia-smi -pm 1
    ${
      if cfg.lolminer.nvidia.perGpuPowerLimits != null then
        ''
          ${lib.concatStringsSep "\n" (
            lib.imap0 (idx: limit: ''
              ${
                if limit == 0 then
                  ''
                    echo "Skipping GPU ${toString idx} (power limit 0 = no limit)"
                  ''
                else
                  ''
                    echo "Setting GPU ${toString idx} power limit to ${toString limit}W..."
                    nvidia-smi -i ${toString idx} -pl ${toString limit}
                  ''
              }
            '') cfg.lolminer.nvidia.perGpuPowerLimits
          )}
        ''
      else if cfg.lolminer.nvidia.powerLimit != null then
        ''
          echo "Setting all GPUs to ${toString cfg.lolminer.nvidia.powerLimit}W..."
          nvidia-smi -pl ${toString cfg.lolminer.nvidia.powerLimit}
        ''
      else
        ''
          echo "No power limit set - letting gpu-workload-monitor manage dynamically"
        ''
    }
    ${
      if cfg.lolminer.nvidia.memoryClockLock != null then
        ''
          echo "Locking all NVIDIA GPU memory clocks to ${toString cfg.lolminer.nvidia.memoryClockLock} MHz..."
          GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1)
          if [ -n "$GPU_COUNT" ]; then
            for i in $(seq 0 $((GPU_COUNT - 1))); do
              echo "Locking GPU $i memory clock to ${toString cfg.lolminer.nvidia.memoryClockLock} MHz..."
              nvidia-smi -i $i -lmc ${toString cfg.lolminer.nvidia.memoryClockLock} || true
            done
          fi
        ''
      else
        ""
    }
    echo "NVIDIA GPU power limits configured successfully"
  '';
  amdGpuPowerLimitScript = pkgs.writeShellScript "amd-gpu-power-limit" ''
    PATH=/run/current-system/sw/bin:$PATH
    echo "Setting AMD GPU power limits..."
    if ! command -v rocm-smi &>/dev/null; then
      echo "Warning: rocm-smi not found, skipping AMD GPU power limits"
      exit 0
    fi
    ${
      if cfg.lolminer.amd.powerLimit != null then
        ''
          echo "Setting AMD GPU power limit to ${toString cfg.lolminer.amd.powerLimit}W..."
          GPU_COUNT=$(rocm-smi --showid | grep -c "GPU\[")
          if [ "$GPU_COUNT" -gt 0 ]; then
            for i in $(seq 0 $((GPU_COUNT - 1))); do
              echo "Setting GPU $i power limit to ${toString cfg.lolminer.amd.powerLimit}W..."
              rocm-smi --setpoweroverdrive ${toString cfg.lolminer.amd.powerLimit} -d $i || true
            done
          fi
        ''
      else
        ''
          echo "No AMD GPU power limit configured"
        ''
    }
    echo "AMD GPU power limits configured successfully"
  '';
  xmrigWrapperScript = pkgs.writeShellScript "xmrig-wrapper" ''
    PATH=/run/current-system/sw/bin:$PATH
    TOKEN_FILE="${cfg.xmrig.httpTokenFile}"
    RUNTIME_CONFIG="/run/xmrig/config.json"
    CONFIG="''${RUNTIME_CONFIG:-/etc/xmrig/config.json}"
    if [ -r "$CONFIG" ]; then
      exec ${pkgs.xmrig}/bin/xmrig -c "$CONFIG" --randomx-1gb-pages --threads=${toString cfg.xmrig.threads}
    else
      exec ${pkgs.xmrig}/bin/xmrig -c /etc/xmrig/config.json --randomx-1gb-pages --threads=${toString cfg.xmrig.threads}
    fi
  '';
in
{
  options.services.mining = {
    enable = mkEnableOption "Robust Mining Services";
    user = mkOption {
      type = types.str;
      default = "mining";
      description = "User to run mining services as";
    };
    lolminer = {
      enable = mkEnableOption "lolMiner Service";
      pools = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              url = mkOption {
                type = types.str;
                description = "Pool URL (format: host:port or stratum+tcp://host:port)";
              };
              wallet = mkOption {
                type = types.str;
                description = "Wallet address or worker ID";
              };
              password = mkOption {
                type = types.str;
                default = "x";
                description = "Pool password (default: 'x')";
              };
              tls = mkOption {
                type = types.bool;
                default = true;
                description = "Enable TLS for this pool connection";
              };
            };
          }
        );
        default = [ ];
        description = "List of pools for failover (priority order). If empty, uses single pool config.";
      };
      algorithm = mkOption {
        type = types.str;
        default = "CR29";
      };
      pool = mkOption {
        type = types.str;
        default = "xtm-c29-us.kryptex.network:8040";
        description = "Mining pool (format: host:port) - only used if pools list is empty";
      };
      wallet = mkOption {
        type = types.str;
        default = defaultWallet;
        description = "Wallet address - only used if pools list is empty";
      };
      tls = mkOption {
        type = types.bool;
        default = true;
        description = "TLS IS REQUIRED for CR29 port 8040 - only used if pools list is empty";
      };
      nvidia = {
        enable = mkEnableOption "NVIDIA GPU Mining";
        autostart = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to automatically start the service at boot. If false, service can be controlled imperatively via systemctl.";
        };
        devices = mkOption {
          type = types.str;
          default = "0";
        };
        powerLimit = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "GPU power limit in watts. Null = let gpu-workload-monitor manage dynamically";
        };
        perGpuPowerLimits = mkOption {
          type = types.nullOr (types.listOf types.int);
          default = null;
          example = [
            130
            250
          ];
          description = "Per-GPU power limits in watts. List index corresponds to GPU ID. Overrides powerLimit if set.";
        };
        memoryClockLock = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 8501;
          description = "Lock NVIDIA memory clock to this value (MHz). Required for Cuckaroo29 on RTX 4060 — without this, lolMiner fails to drive memory clocks up, resulting in ~0.2 g/s instead of ~4 g/s. Use the max mem clock from nvidia-smi --query-gpu=clocks.max.mem.";
        };
        apiPort = mkOption {
          type = types.int;
          default = 4068;
        };
      };
      amd = {
        enable = mkEnableOption "AMD GPU Mining";
        autostart = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to automatically start the service at boot. If false, service can be controlled imperatively via systemctl.";
        };
        devices = mkOption {
          type = types.str;
          default = "0";
        };
        powerLimit = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "GPU power limit in watts. Null = let gpu-workload-monitor manage dynamically";
        };
        apiPort = mkOption {
          type = types.int;
          default = 4069;
        };
      };
    };
    xmrig = {
      enable = mkEnableOption "XMRig Service";
      autostart = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to automatically start the service at boot. If false, service can be controlled imperatively via systemctl.";
      };
      pool = mkOption {
        type = types.str;
        default = "xtm-rx-us.kryptex.network:8038";
      };
      wallet = mkOption {
        type = types.str;
        default = defaultWallet;
      };
      password = mkOption {
        type = types.str;
        default = "x";
      };
      threads = mkOption {
        type = types.int;
        default = 16;
      };
      httpTokenFile = mkOption {
        type = types.path;
        default = "/run/agenix/xmrig-api-token";
        description = "Path to the HTTP API token file (managed by agenix)";
      };
      tls = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to use TLS for pool connection. Set to false when using xmrig-proxy.";
      };
    };
  };
  config = mkIf cfg.enable {


    assertions = [
      {
        assertion =
          cfg.lolminer.nvidia.enable
          -> (cfg.lolminer.nvidia.devices != "" && cfg.lolminer.nvidia.devices != "0");
        message = ''
          NVIDIA mining is enabled but no GPU devices are configured.
          Current configuration:
            services.mining.lolminer.nvidia.devices = "${cfg.lolminer.nvidia.devices}"
          Configure GPU devices:
            services.mining.lolminer.nvidia.devices = "0";
            services.mining.lolminer.nvidia.devices = "0,1";
          Or disable NVIDIA mining:
            services.mining.lolminer.nvidia.enable = false;
        '';
      }
      {
        assertion = cfg.lolminer.amd.enable -> (cfg.lolminer.amd.devices != "");
        message = ''
          AMD mining is enabled but no GPU devices are configured.
          Current configuration:
            services.mining.lolminer.amd.devices = "${cfg.lolminer.amd.devices}"
          Configure GPU devices:
            services.mining.lolminer.amd.devices = "1";
          Or disable AMD mining:
            services.mining.lolminer.amd.enable = false;
        '';
      }
      {
        assertion = cfg.xmrig.enable -> (cfg.xmrig.pool != "");
        message = ''
          XMRig is enabled but no mining pool is configured.
          Configure a mining pool:
            services.mining.xmrig.pool = "pool.example.com:port";
          Or disable XMRig:
            services.mining.xmrig.enable = false;
        '';
      }
      {
        assertion = cfg.xmrig.enable -> (cfg.xmrig.wallet != "");
        message = ''
          XMRig is enabled but no wallet address is configured.
          Configure a wallet address:
            services.mining.xmrig.wallet = "your-wallet-address";
          Or disable XMRig:
            services.mining.xmrig.enable = false;
        '';
      }
      {
        assertion = cfg.xmrig.threads > 0;
        message = ''
          Invalid XMRig thread count: ${toString cfg.xmrig.threads}
          Thread count must be greater than 0.
          Recommended: Set to number of CPU cores or use autodetection.
        '';
      }
      {
        assertion =
          !(
            cfg.lolminer.nvidia.enable
            && cfg.xmrig.enable
            && cfg.lolminer.nvidia.powerLimit != null
            && cfg.lolminer.nvidia.powerLimit < 50
          );
        message = ''
          NVIDIA GPU power limit is too low for combined mining.
          Current configuration:
            lolminer.nvidia.powerLimit = ${toString cfg.lolminer.nvidia.powerLimit}
          When running both lolminer and xmrig on NVIDIA GPUs, power limit should be at least 50W to avoid performance issues.
          Recommended: 80-120W for RTX 3060 Ti, 90-130W for RTX 3090
        '';
      }
    ];
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = "mining";
      extraGroups = [
        "video"
        "render"
      ];
    };
    users.groups.mining = { };
    boot = {
      kernel.sysctl = {
        "vm.nr_hugepages" = 1280;
      };
      kernelModules = [ "msr" ];
      kernelParams = [
        "hugepagesz=1G"
        "hugepages=3"
        "msr.allow_writes=on"
      ];
    };
    services.udev.extraRules = ''
      KERNEL=="msr", MODE="0666"
    '';
    environment.systemPackages = [ pkgs.lolminer ];
    fileSystems."/dev/hugepages-1gb" = {
      device = "none";
      fsType = "hugetlbfs";
      options = [ "pagesize=1G" ];
    };
    systemd.tmpfiles.rules = [
      "L+ /dev/cpu/msr - - - - /dev/cpu/0/msr"
      "d /var/lib/mining 0750 ${cfg.user} mining - -"
      "d /var/log/mining 0750 ${cfg.user} mining - -"
      "d /run/xmrig 0750 ${cfg.user} mining - -"
    ];
    environment.etc."xmrig/config.json" = mkIf cfg.xmrig.enable {
      text = builtins.toJSON {
        api = {
          id = null;
          worker-id = null;
        };
        http = {
          enabled = true;
          host = "127.0.0.1";
          port = 8081;
          restricted = false;
        };
        pools = [
          {
            url = cfg.xmrig.pool;
            user = cfg.xmrig.wallet;
            pass = cfg.xmrig.password or "x";
            inherit (cfg.xmrig) tls;
            keepalive = true;
            nicehash = false;
          }
          {
            url = "xtm-rx-eu.kryptex.network:8038";
            user = cfg.xmrig.wallet;
            pass = cfg.xmrig.password or "x";
            inherit (cfg.xmrig) tls;
            keepalive = true;
            nicehash = false;
          }
          {
            url = "xtm-rx-asia.kryptex.network:8038";
            user = cfg.xmrig.wallet;
            pass = cfg.xmrig.password or "x";
            inherit (cfg.xmrig) tls;
            keepalive = true;
            nicehash = false;
          }
        ];
        randomx = {
          "1gb-pages" = true;
          mode = "fast";
        };
        asm = true;
        cpu = {
          enabled = true;
          "huge-pages" = true;
          "huge-pages-jit" = false;
          "hw-aes" = null;
          priority = null;
          "memory-pool" = false;
          yield = true;
          inherit (cfg.xmrig) threads;
        };
        logging = {
          type = "stdout";
          level = "0";
        };
      };
    };
    systemd = {
      targets.mining = {
        description = "All mining services";
        wants =
          lib.optionals cfg.lolminer.nvidia.enable [ "lolminer-nvidia.service" ]
          ++ lib.optionals cfg.lolminer.amd.enable [ "lolminer-amd.service" ]
          ++ lib.optionals cfg.xmrig.enable [ "xmrig.service" ]
          ++ [ "network-online.target" ];
        after = [ "network-online.target" ];
      };
      services = {
        nvidia-gpu-power-limit =
          mkIf
            (
              cfg.lolminer.nvidia.perGpuPowerLimits != null
              || cfg.lolminer.nvidia.powerLimit != null
              || cfg.lolminer.nvidia.memoryClockLock != null
            )
            {
              description = "Set NVIDIA GPU Power Limit for Mining";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = nvidiaGpuPowerLimitScript;
                RemainAfterExit = true;
              };
            };
        amd-gpu-power-limit = mkIf (cfg.lolminer.amd.powerLimit != null) {
          description = "Set AMD GPU Power Limit for Mining";
          wantedBy = [ "multi-user.target" ];
          before = lib.optionals cfg.lolminer.amd.enable [ "lolminer-amd.service" ];
          requiredBy = lib.optionals cfg.lolminer.amd.enable [ "lolminer-amd.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = amdGpuPowerLimitScript;
            RemainAfterExit = true;
          };
        };
        lolminer-nvidia = mkIf cfg.lolminer.nvidia.enable {
          description = "lolMiner NVIDIA Mining Service";
          wantedBy = mkIf cfg.lolminer.nvidia.autostart [ "multi-user.target" ];
          after = [
            "network.target"
            "nvidia-gpu-power-limit.service"
          ];
          requires = [ "nvidia-gpu-power-limit.service" ];
          serviceConfig = {
            User = cfg.user;
            Group = "mining";
            Slice = "mining.slice";
            ExecStart =
              let
                poolArgs =
                  pools:
                  lib.concatMapStrings (p: ''
                    --pool ${p.url} \
                    --user ${p.wallet} \
                    --pass ${p.password} \
                    --tls ${if p.tls then "on" else "off"} \
                  '') pools;
                poolsToUse =
                  if cfg.lolminer.pools != [ ] then
                    cfg.lolminer.pools
                  else
                    [
                      {
                        url = "xtm-c29-us.kryptex.network:8040";
                        inherit (cfg.lolminer) wallet;
                        password = "x";
                        tls = true;
                      }
                      {
                        url = "xtm-c29-eu.kryptex.network:8040";
                        inherit (cfg.lolminer) wallet;
                        password = "x";
                        tls = true;
                      }
                      {
                        url = "xtm-c29-asia.kryptex.network:8040";
                        inherit (cfg.lolminer) wallet;
                        password = "x";
                        tls = true;
                      }
                    ];
              in
              ''
                ${pkgs.lolminer}/bin/lolMiner \
                  --algo ${cfg.lolminer.algorithm} \
                  ${poolArgs poolsToUse}\
                  --devices ${cfg.lolminer.nvidia.devices} \
                  --apiport ${toString cfg.lolminer.nvidia.apiPort} \
                  --mode b
              '';
            Restart = "always";
            RestartSec = "30s";
            Environment = [
              "GPU_MAX_HEAP_SIZE=100"
              "GPU_MAX_ALLOC_PERCENT=100"
              "OCL_ICD_VENDORS=/etc/OpenCL/vendors"
            ];
            LimitMEMLOCK = "4G";
          }
          // lolminerHardening;
        };
        lolminer-amd = mkIf cfg.lolminer.amd.enable {
          description = "lolMiner AMD Mining Service";
          wantedBy = mkIf cfg.lolminer.amd.autostart [ "multi-user.target" ];
          after = [
            "network.target"
            "amd-gpu-power-limit.service"
          ];
          requires = [ "amd-gpu-power-limit.service" ];
          serviceConfig = {
            User = cfg.user;
            Group = "mining";
            Slice = "mining.slice";
            ExecStart =
              let
                poolArgs =
                  pools:
                  lib.concatMapStrings (p: ''
                    --pool ${p.url} \
                    --user ${p.wallet} \
                    --pass ${p.password} \
                    --tls ${if p.tls then "on" else "off"} \
                  '') pools;
                poolsToUse =
                  if cfg.lolminer.pools != [ ] then
                    cfg.lolminer.pools
                  else
                    [
                      {
                        url = "xtm-c29-us.kryptex.network:8040";
                        inherit (cfg.lolminer) wallet;
                        password = "x";
                        tls = true;
                      }
                      {
                        url = "xtm-c29-eu.kryptex.network:8040";
                        inherit (cfg.lolminer) wallet;
                        password = "x";
                        tls = true;
                      }
                      {
                        url = "xtm-c29-asia.kryptex.network:8040";
                        inherit (cfg.lolminer) wallet;
                        password = "x";
                        tls = true;
                      }
                    ];
              in
              ''
                ${pkgs.lolminer}/bin/lolMiner \
                  --algo ${cfg.lolminer.algorithm} \
                  ${poolArgs poolsToUse}\
                  --devices ${cfg.lolminer.amd.devices} \
                  --apiport ${toString cfg.lolminer.amd.apiPort} \
                  --mode b
              '';
            Restart = "always";
            RestartSec = "30s";
            Environment = [
              "OCL_ICD_VENDORS=/etc/OpenCL/vendors"
            ];
            LimitMEMLOCK = "8G";
          }
          // lolminerHardening;
        };
        xmrig = mkIf cfg.xmrig.enable {
          description = "XMRig CPU Mining Service";
          wantedBy = mkIf cfg.xmrig.autostart [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            User = cfg.user;
            Group = "mining";
            Slice = "mining.slice";
            ExecStartPre = pkgs.writeShellScript "xmrig-config-prep-v5" ''
              TOKEN_FILE="${cfg.xmrig.httpTokenFile}"
              CONFIG_DIR=/run/xmrig
              mkdir -p "$CONFIG_DIR"
              if [ -r "$TOKEN_FILE" ]; then
                TOKEN=$(cat "$TOKEN_FILE")
                ${pkgs.jq}/bin/jq ".http.\"access-token\" = \"$TOKEN\"" /etc/xmrig/config.json > "$CONFIG_DIR/config.json"
              else
                cp /etc/xmrig/config.json "$CONFIG_DIR/config.json"
              fi
              chmod 640 "$CONFIG_DIR/config.json"
            '';
            ExecStart = xmrigWrapperScript;
            Restart = "always";
            NoNewPrivileges = false;
            PrivateTmp = true;
            ProtectKernelTunables = false;
            ProtectControlGroups = true;
            ProtectHostname = true;
            RestrictRealtime = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadOnlyPaths = "/";
            ReadWritePaths = [
              "/var/lib/mining"
              "/var/log/mining"
              "/run/xmrig"
            ];
            LimitMEMLOCK = "4G";
            CapabilityBoundingSet = "CAP_SYS_RAWIO";
            AmbientCapabilities = "CAP_SYS_RAWIO";
            DeviceAllow = [
              "/dev/cpu/*/msr"
              "/dev/msr"
            ];
          };
        };
      };
    };
    networking.firewall.interfaces.lo.allowedTCPPorts = [
      cfg.lolminer.nvidia.apiPort
      cfg.lolminer.amd.apiPort
      8081
    ];
  };
}
