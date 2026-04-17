{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.xmrig-metrics;
  inherit (lib)
    mkEnableOption
    mkOption
    types
    mkIf
    ;

  xmrigMetricsScript = pkgs.writeScript "xmrig-metrics" ''
    #!/usr/bin/env python3
    import json, sys, time, urllib.request

    def safe_float(v, d=0.0):
        try: return float(v)
        except: return d

    def safe_int(v, d=0):
        try: return int(v)
        except: return d

    def scrape(host, port, timeout=5):
        url = f"http://{host}:{port}/1/summary"
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                data = json.loads(r.read())
        except Exception as e:
            print(f"# scrape_error{{host=\"{host}\",port=\"{port}\"}} 1  # {e}", file=sys.stderr)
            return []
        w = data.get("worker_id", "unknown")
        hr = data.get("hashrate", {})
        t = hr.get("total", [0,0,0])
        hi = hr.get("highest", 0)
        th = hr.get("threads", [])
        hp = data.get("hugepages", {})
        cn = data.get("connection", {})
        ha = safe_int(hp.get("allocated", 0)) if isinstance(hp, dict) else 0
        ht = safe_int(hp.get("total", 0)) if isinstance(hp, dict) else 0
        lines = [
            f"xmrig_hashrate_total{{worker=\"{w}\",host=\"{host}\",port=\"{port}\",interval=\"10s\"}} {safe_float(t[0]):.2f}",
            f"xmrig_hashrate_total{{worker=\"{w}\",host=\"{host}\",port=\"{port}\",interval=\"60s\"}} {safe_float(t[1]):.2f}",
            f"xmrig_hashrate_total{{worker=\"{w}\",host=\"{host}\",port=\"{port}\",interval=\"15m\"}} {safe_float(t[2]):.2f}",
            f"xmrig_hashrate_highest{{worker=\"{w}\",host=\"{host}\",port=\"{port}\"}} {safe_float(hi):.2f}",
            f"xmrig_threads{{worker=\"{w}\",host=\"{host}\",port=\"{port}\"}} {len(th)}",
            f"xmrig_hugepages{{worker=\"{w}\",host=\"{host}\",port=\"{port}\"}} {ha}",
            f"xmrig_hugepages_total{{worker=\"{w}\",host=\"{host}\",port=\"{port}\"}} {ht}",
            f"xmrig_up{{worker=\"{w}\",host=\"{host}\",port=\"{port}\"}} 1",
            f"xmrig_connected{{worker=\"{w}\",host=\"{host}\",port=\"{port}\"}} {1 if cn else 0}",
        ]
        for i, x in enumerate(th):
            if x and len(x) >= 2:
                lines.append(f"xmrig_hashrate_thread{{worker=\"{w}\",host=\"{host}\",port=\"{port}\",thread=\"{i}\"}} {safe_float(x[1]):.2f}")
        return lines

    if __name__ == "__main__":
        if len(sys.argv) < 2:
            print("Usage: xmrig-metrics.py <host:port> [host:port ...]", file=sys.stderr)
            sys.exit(1)
        all_lines = []
        for target in sys.argv[1:]:
            host, port = target.rsplit(":", 1)
            all_lines.extend(scrape(host, port))
        print(f"# xmrig metrics at {time.time():.0f}")
        print("\n".join(all_lines))
  '';

  targetArgs = lib.concatStringsSep " " cfg.targets;

  textfileDir = "/var/lib/prometheus/node-exporter/textfile-collector";
in
{
  options.services.xmrig-metrics = {
    enable = mkEnableOption "XMRig metrics exporter (node-exporter textfile collector)";
    interval = mkOption {
      type = types.int;
      default = 30;
      description = "Scrape interval in seconds";
    };
    targets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "List of host:port targets to scrape (local xmrig JSON APIs)";
      example = [
        "127.0.0.1:8082"
        "127.0.0.1:8083"
      ];
    };
  };

  config = mkIf cfg.enable {
    systemd.services.xmrig-metrics = {
      description = "Scrape XMRig JSON API and write prometheus metrics";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "prometheus-node-exporter.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "xmrig-metrics-scrape" ''
          OUT="${textfileDir}/xmrig.prom.tmp"
          ${lib.getExe' pkgs.python3 "python3"} ${xmrigMetricsScript} ${targetArgs} > "$OUT"
          if ! grep -qP '^[^#].*[^ ]$' "$OUT" 2>/dev/null; then
            echo "# xmrig metrics - no miners responding" > "$OUT"
          fi
          mv -f "$OUT" "${textfileDir}/xmrig.prom"
        '';
        TimeoutStartSec = "15";
      };
    };

    systemd.timers.xmrig-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "${toString cfg.interval}s";
        AccuracySec = "5s";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 node-exporter node-exporter -"
    ];
  };
}
