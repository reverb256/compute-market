{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;

  cfg = config.services.mining-exporter;

  httpServerScript = pkgs.writeText "mining-exporter-http-server.py" ''
    import http.server
    import socketserver
    import sys
    import os

    PORT = int(sys.argv[1])
    METRICS_FILE = sys.argv[2]

    class MetricsHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/metrics':
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
                self.end_headers()
                if os.path.exists(METRICS_FILE):
                    with open(METRICS_FILE, 'r') as f:
                        self.wfile.write(f.read().encode('utf-8'))
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            pass

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), MetricsHandler) as httpd:
        httpd.serve_forever()
  '';

  hosts = {
    zephyr = {
      nvidia = true;
      amd = false;
      cpu = true;
      lolminerPort = 4068;
      xmrigPort = 8081;
    };
    nexus = {
      nvidia = true;
      amd = false;
      cpu = true;
      lolminerPort = 4068;
      xmrigPort = 8081;
    };
    forge = {
      nvidia = true;
      amd = true;
      cpu = false;
      lolminerPort = 4068;
      lolminerAmdPort = 4069;
      xmrigPort = 8081;
    };
    sentry = {
      nvidia = false;
      amd = false;
      cpu = true;
      xmrigPort = 8081;
    };
  };

  currentHost = config.networking.hostName;
  hostConfig = hosts.${currentHost} or null;
in
{
  options.services.mining-exporter = {
    enable = mkEnableOption "Mining metrics exporter for Prometheus";

    port = mkOption {
      type = types.port;
      default = 9105;
      description = "Port for mining metrics exporter";
    };

    scrapeInterval = mkOption {
      type = types.str;
      default = "15s";
      description = "How often to poll mining APIs";
    };
  };

  config = mkIf (cfg.enable && hostConfig != null) {
    systemd.services.prometheus-mining-exporter = {
      description = "Prometheus Mining Metrics Exporter";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = pkgs.writers.writeBash "mining-exporter" ''
          set -euo pipefail

          PORT=${toString cfg.port}
          HOSTNAME="$(${pkgs.hostname}/bin/hostname)"
          INTERVAL_SECONDS=15

          METRICS_DIR="/run/prometheus-mining-exporter"
          cd "$METRICS_DIR"

          escape_label() {
            ${pkgs.gnused}/bin/sed 's/"/\\"/g; s/[^a-zA-Z0-9:_]/_/g'
          }

          HOST_LABEL="'$(echo "$HOSTNAME" | escape_label):${toString cfg.port}'"

          METRICS_FILE="$METRICS_DIR/metrics.tmp"

          fetch_lolminer() {
            local port=$1
            local gpu_type=$2

            if ! ${pkgs.curl}/bin/curl -s http://localhost:"$port" > /tmp/lolminer_"$gpu_type".json 2>/dev/null; then
              return
            fi

            {
              echo "# HELP mining_lolminer_hashrate_total Total hashrate for lolminer"
              echo "# TYPE mining_lolminer_hashrate_total gauge"
              HASHRATE=$(${pkgs.jq}/bin/jq -r '.Algorithms[0].Total_Performance // 0' /tmp/lolminer_"$gpu_type".json 2>/dev/null || echo "0")
              echo "mining_lolminer_hashrate_total{instance=$HOST_LABEL,gpu_type=\"$gpu_type\"} $HASHRATE"

              echo "# HELP mining_lolminer_hashrate_per_gpu Hashrate per GPU"
              echo "# TYPE mining_lolminer_hashrate_per_gpu gauge"
              ${pkgs.jq}/bin/jq -r --arg hostname "$HOSTNAME" --arg gputype "$gpu_type" '.Algorithms[0].Worker_Performance as $perf | .Workers as $workers | range(0; $workers | length) | "mining_lolminer_hashrate_per_gpu{instance=\"" + $hostname + "\",gpu_type=\"" + $gputype + "\",gpu_id=\"" + ($workers[.].Index | tostring) + "\",gpu_name=\"" + ($workers[.].Name // "unknown") + "\"} " + ($perf[.] // "0" | tostring)' /tmp/lolminer_"$gpu_type".json 2>/dev/null || true

              echo "# HELP mining_lolminer_shares_accepted Total accepted shares"
              echo "# TYPE mining_lolminer_shares_accepted counter"
              ACCEPTED=$(${pkgs.jq}/bin/jq -r '.Algorithms[0].Total_Accepted // 0' /tmp/lolminer_"$gpu_type".json 2>/dev/null || echo "0")
              echo "mining_lolminer_shares_accepted{instance=$HOST_LABEL,gpu_type=\"$gpu_type\"} $ACCEPTED"

              echo "# HELP mining_lolminer_shares_rejected Total rejected shares"
              echo "# TYPE mining_lolminer_shares_rejected counter"
              REJECTED=$(${pkgs.jq}/bin/jq -r '.Algorithms[0].Total_Rejected // 0' /tmp/lolminer_"$gpu_type".json 2>/dev/null || echo "0")
              echo "mining_lolminer_shares_rejected{instance=$HOST_LABEL,gpu_type=\"$gpu_type\"} $REJECTED"

              echo "# HELP mining_lolminer_uptime_seconds Uptime in seconds"
              echo "# TYPE mining_lolminer_uptime_seconds gauge"
              UPTIME=$(${pkgs.jq}/bin/jq -r '.Session.Uptime // 0' /tmp/lolminer_"$gpu_type".json 2>/dev/null || echo "0")
              echo "mining_lolminer_uptime_seconds{instance=$HOST_LABEL,gpu_type=\"$gpu_type\"} $UPTIME"

              echo "# HELP mining_lolminer_power_watts Power consumption"
              echo "# TYPE mining_lolminer_power_watts gauge"
              ${pkgs.jq}/bin/jq -r --arg hostname "$HOSTNAME" --arg gputype "$gpu_type" '.Workers[] | "mining_lolminer_power_watts{instance=\"" + $hostname + "\",gpu_type=\"" + $gputype + "\",gpu_id=\"" + (.Index | tostring) + "\",gpu_name=\"" + (.Name // "unknown") + "\"} " + (.Power // "0" | tostring)' /tmp/lolminer_"$gpu_type".json 2>/dev/null || true

              echo "# HELP mining_lolminer_temperature_celsius GPU temperature"
              echo "# TYPE mining_lolminer_temperature_celsius gauge"
              ${pkgs.jq}/bin/jq -r --arg hostname "$HOSTNAME" --arg gputype "$gpu_type" '.Workers[] | "mining_lolminer_temperature_celsius{instance=\"" + $hostname + "\",gpu_type=\"" + $gputype + "\",gpu_id=\"" + (.Index | toString) + "\",gpu_name=\"" + (.Name // "unknown") + "\"} " + (.Core_Temp // "0" | tostring)' /tmp/lolminer_"$gpu_type".json 2>/dev/null || true

              echo ""
            } >> "$METRICS_FILE"
          }

          fetch_xmrig() {
            local port=$1

            if ! ${pkgs.curl}/bin/curl -s http://localhost:"$port"/1/summary -H "Authorization: Bearer mining-exporter-token" > /tmp/xmrig.json 2>/dev/null; then
              return
            fi

            {
              echo "# HELP mining_xmrig_hashrate_total Total hashrate for xmrig"
              echo "# TYPE mining_xmrig_hashrate_total gauge"
              HASHRATE=$(${pkgs.jq}/bin/jq -r '.hashrate.total[0] // 0' /tmp/xmrig.json 2>/dev/null || echo "0")
              echo "mining_xmrig_hashrate_total{instance=$HOST_LABEL} $HASHRATE"

              echo "# HELP mining_xmrig_hashrate_per_thread Hashrate per thread"
              echo "# TYPE mining_xmrig_hashrate_per_thread gauge"
              ${pkgs.jq}/bin/jq -r --arg hostname "$HOSTNAME" '.hashrate.threads[] | "mining_xmrig_hashrate_per_thread{instance=\"" + $hostname + "\",thread=\"" + (.index | tostring) + "\"} " + (.hashrate // 0 | tostring)' /tmp/xmrig.json 2>/dev/null || true

              echo "# HELP mining_xmrig_shares_accepted Total accepted shares"
              echo "# TYPE mining_xmrig_shares_accepted counter"
              ACCEPTED=$(${pkgs.jq}/bin/jq -r '.shares.accepted // 0' /tmp/xmrig.json 2>/dev/null || echo "0")
              echo "mining_xmrig_shares_accepted{instance=$HOST_LABEL} $ACCEPTED"

              echo "# HELP mining_xmrig_shares_rejected Total rejected shares"
              echo "# TYPE mining_xmrig_shares_rejected counter"
              REJECTED=$(${pkgs.jq}/bin/jq -r '.shares.rejected // 0' /tmp/xmrig.json 2>/dev/null || echo "0")
              echo "mining_xmrig_shares_rejected{instance=$HOST_LABEL} $REJECTED"

              echo ""
            } >> "$METRICS_FILE"
          }

          ${lib.optionalString (hostConfig ? lolminerPort) ''
            fetch_lolminer ${toString (hostConfig.lolminerPort or 4068)} "nvidia" &
          ''}
          ${lib.optionalString (hostConfig ? lolminerAmdPort) ''
            fetch_lolminer ${toString (hostConfig.lolminerAmdPort or 4069)} "amd" &
          ''}
          ${lib.optionalString (hostConfig ? xmrigPort) ''
            fetch_xmrig ${toString hostConfig.xmrigPort} &
          ''}
          wait

            ${pkgs.python3}/bin/python3 ${httpServerScript} ${toString cfg.port} "$METRICS_FILE"

            sleep "$INTERVAL_SECONDS"
          done
        '';
        Path = [
          pkgs.curl
          pkgs.hostname
          pkgs.jq
          pkgs.gnused
          pkgs.coreutils
        ];
        StandardError = "journal";
        NoNewPrivileges = true;
        PrivateTmp = true;
        RuntimeDirectory = "prometheus-mining-exporter";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = "/";
        ReadWritePaths = "/run/prometheus-mining-exporter";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkOptionDefault [ cfg.port ];
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
