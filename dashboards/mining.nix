{lib, ...}: let
  inherit (lib.dashboard) panels template thresholds;
in {
  mining = template {
    title = "⛏️ Mining Operations";
    description = "Real-time mining performance, hashrates, and efficiency metrics";
    tags = ["mining" "gpu" "performance"];
    panels = [
      (panels.row "📊 Mining Overview" false)
      (panels.statPanel {
        title = "Total Hashrate";
        expr = "sum(mining_worker_hashrate)";
        gridPos = {
          h = 6;
          w = 6;
          x = 0;
          y = 1;
        };
        unit = "hertz";
        colorMode = "value";
      })
      (panels.statPanel {
        title = "Active Workers";
        expr = "count(mining_worker_hashrate > 0)";
        gridPos = {
          h = 6;
          w = 6;
          x = 6;
          y = 1;
        };
        thresholds = [
          {
            color = "red";
            value = null;
          }
          {
            color = "green";
            value = 1;
          }
        ];
        colorMode = "background";
      })
      (panels.statPanel {
        title = "Shares (Last 5m)";
        expr = "sum(rate(mining_shares_accepted[5m]) * 300)";
        gridPos = {
          h = 6;
          w = 6;
          x = 12;
          y = 1;
        };
        colorMode = "value";
      })
      (panels.gauge {
        title = "Rejection Rate";
        expr = "sum(rate(mining_shares_rejected[5m])) / (sum(rate(mining_shares_rejected[5m])) + sum(rate(mining_shares_accepted[5m]))) * 100";
        gridPos = {
          h = 6;
          w = 6;
          x = 18;
          y = 1;
        };
        thresholds = [
          {
            color = "green";
            value = null;
          }
          {
            color = "yellow";
            value = 2;
          }
          {
            color = "orange";
            value = 5;
          }
          {
            color = "red";
            value = 10;
          }
        ];
        unit = "percent";
      })

      (panels.row "🖥️ Hashrate by Host" false)
      (panels.timeseries {
        title = "Hashrate by Host";
        expr = "sum by (host) (mining_worker_hashrate)";
        gridPos = {
          h = 10;
          w = 16;
          x = 0;
          y = 7;
        };
        unit = "hertz";
        legendFormat = "{{host}}";
      })
      (panels.piechart {
        title = "Hashrate Distribution";
        expr = "sum(mining_worker_hashrate) by (host)";
        gridPos = {
          h = 10;
          w = 8;
          x = 16;
          y = 7;
        };
      })

      (panels.row "🎮 GPU Analysis" true)
      (panels.timeseries {
        title = "Hashrate by GPU";
        expr = "mining_worker_hashrate";
        gridPos = {
          h = 10;
          w = 24;
          x = 0;
          y = 17;
        };
        unit = "hertz";
        legendFormat = "{{host}} {{gpu_id}} ({{name}})";
      })

      (panels.row "⚡ Efficiency Metrics" true)
      (panels.timeseries {
        title = "Hashrate per Watt";
        expr = "mining_worker_hashrate / nvidia_smi_power_draw_watts";
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 27;
        };
        legendFormat = "{{host}} {{gpu_id}}";
      })
      (panels.timeseries {
        title = "Power Consumption";
        expr = "sum by (host) (nvidia_smi_power_draw_watts)";
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 27;
        };
        unit = "watt";
        legendFormat = "{{host}}";
      })

      (panels.row "🌡️ GPU Temperatures" true)
      (panels.timeseries {
        title = "GPU Temperatures";
        expr = "nvidia_smi_temperature_gpu";
        gridPos = {
          h = 10;
          w = 24;
          x = 0;
          y = 35;
        };
        thresholds = thresholds.temperature;
        unit = "celsius";
        legendFormat = "{{host}} {{gpu_id}}";
      })

      (panels.row "📈 Performance History" true)
      {
        datasource = lib.dashboard.prometheusDatasource;
        fieldConfig.defaults = {
          color.mode = "palette-classic";
          custom = {
            axisCenteredZero = false;
            axisColorMode = "text";
            drawStyle = "line";
            fillOpacity = 10;
            gradientMode = "scheme";
            lineInterpolation = "smooth";
            lineWidth = 2;
            spanNulls = true;
          };
          unit = "hertz";
        };
        gridPos = {
          h = 10;
          w = 24;
          x = 0;
          y = 45;
        };
        options = {
          legend = {
            calcs = ["mean" "max"];
            displayMode = "table";
            placement = "bottom";
          };
          tooltip.mode = "multi";
        };
        targets = [
          {
            expr = "avg_over_time(sum(mining_worker_hashrate)[24h:1h])";
            legendFormat = "24h Average";
            refId = "A";
          }
          {
            expr = "sum(mining_worker_hashrate)";
            legendFormat = "Current";
            refId = "B";
          }
        ];
        title = "Hashrate: Current vs 24h Average";
        type = "timeseries";
      }
    ];
  };
}
