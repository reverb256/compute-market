{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.services.compute-market = {
    enable = lib.mkEnableOption "GPU Resource Marketplace - unified auction engine for GPU allocation";

    auctionInterval = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Auction interval in seconds";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/run/compute-market";
      description = "Directory for auction state and bidding information";
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/compute-market.log";
      description = "Path to log file";
    };

    bidders.mining = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable mining as baseline bidder";
      };

      hourlyRevenue = lib.mkOption {
        type = lib.types.float;
        default = 0.014;
        description = "Hourly revenue per GPU in USD (actual: ~$96/month / 7 GPUs / 730 hrs)";
      };

      services = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "lolminer-nvidia"
          "lolminer-amd"
          "xmrig"
        ];
        description = "Mining services to manage";
      };
    };

    bidders.kubernetes = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Kubernetes workload bidder";
      };

      baseBid = lib.mkOption {
        type = lib.types.float;
        default = 2.50;
        description = "Base hourly bid per GPU in USD for K8s workloads";
      };

      urgencyMultiplier = lib.mkOption {
        type = lib.types.float;
        default = 2.0;
        description = "Multiplier for jobs with deadlines";
      };

      namespace = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Kubernetes namespace to monitor for GPU workloads";
      };
    };

    bidders.akash = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Akash Network lease bidder";
      };

      profitMargin = lib.mkOption {
        type = lib.types.float;
        default = 0.90;
        description = "Percentage of market price to bid (0.90 = bid 90% of market rate)";
      };

      namespace = lib.mkOption {
        type = lib.types.str;
        default = "akash-services";
        description = "Akash provider namespace";
      };
    };

    bidders.gaming = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable gaming as priority override (always wins)";
      };

      processes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "steam\\.exe"
          "steamwebhelper"
          "steamapps"
          "/Steam/"
          "lutris\\.bin"
          "heroic"
          "HeroicGamesLauncher"
          "wine(32|64)\\.exe"
          "proton:"
        ];
        description = "Process names that indicate gaming activity";
      };
    };

    prometheus = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Prometheus metrics exporter";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 9200;
        description = "Port for Prometheus metrics";
      };
    };
  };

  config =
    let
      cfg = config.services.compute-market;
    in
    lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.auctionInterval > 0;
          message = ''
            GPU Marketplace requires a positive auction interval.
            Current value: ${toString cfg.auctionInterval}
            Recommended minimum: 30 (seconds)
            Recommended maximum: 300 (5 minutes)
          '';
        }
        {
          assertion = cfg.bidders.mining.hourlyRevenue >= 0.0;
          message = ''
            Mining hourly revenue cannot be negative.
            Current value: ${toString cfg.bidders.mining.hourlyRevenue}
          '';
        }
        {
          assertion = cfg.bidders.kubernetes.baseBid >= 0.0;
          message = ''
            Kubernetes base bid cannot be negative.
            Current value: ${toString cfg.bidders.kubernetes.baseBid}
          '';
        }
        {
          assertion = cfg.bidders.kubernetes.urgencyMultiplier >= 1.0;
          message = ''
            Kubernetes urgency multiplier must be >= 1.0.
            Current value: ${toString cfg.bidders.kubernetes.urgencyMultiplier}
          '';
        }
        {
          assertion = cfg.bidders.akash.profitMargin > 0.0 && cfg.bidders.akash.profitMargin <= 1.0;
          message = ''
            Akash profit margin must be between 0.0 and 1.0.
            Current value: ${toString cfg.bidders.akash.profitMargin}
          '';
        }
        {
          assertion = lib.any (bidder: bidder.enable) (lib.attrValues cfg.bidders);
          message = "GPU Marketplace requires at least one bidder to be enabled.";
        }
        {
          assertion = cfg.prometheus.port > 0 && cfg.prometheus.port < 65536;
          message = "Invalid Prometheus metrics port: ${toString cfg.prometheus.port}";
        }
      ];

      environment.systemPackages = with pkgs; [
        procps
        systemd
        bc
        curl
        jq
        coreutils
        util-linux
      ];

      systemd.tmpfiles.rules = [
        "d ${config.services.compute-market.stateDirectory} 0755 root root -"
        "d ${config.services.compute-market.stateDirectory}/bidders 0755 root root -"
      ];

      systemd.services.compute-market = {
        description = "GPU Resource Marketplace Auction Engine";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
        ];
        wants = [ "prometheus-node-exporter.service" ];

        path = with pkgs; [
          procps
          systemd
          bc
          curl
          jq
          coreutils
          util-linux
        ];

        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = "10s";
          Environment = [
            "PATH=${
              lib.makeBinPath (
                with pkgs;
                [
                  procps
                  systemd
                  bc
                  curl
                  jq
                  coreutils
                  util-linux
                ]
              )
            }:/run/current-system/sw/bin"
            "STATE_DIR=${config.services.compute-market.stateDirectory}"
            "LOG_FILE=${config.services.compute-market.logFile}"
          ];
          ExecStart = "${pkgs.writeShellScriptBin "compute-market-engine" ''

            set -euo pipefail

            STATE_DIR="''${STATE_DIR:-/run/compute-market}"
            LOG_FILE="''${LOG_FILE:-/var/log/compute-market.log}"
            AUCTION_INTERVAL=''${AUCTION_INTERVAL:-30}
            PROMETHEUS_PORT=''${PROMETHEUS_PORT:-9200}

            MINING_ENABLE=''${MINING_ENABLE:-true}
            MINING_HOURLY=''${MINING_HOURLY:-0.10}
            MINING_SERVICES="''${MINING_SERVICES:-lolminer-nvidia xmrig}"

            K8S_ENABLE=''${K8S_ENABLE:-false}
            K8S_BASE_BID=''${K8S_BASE_BID:-2.50}
            K8S_URGENCY_MULT=''${K8S_URGENCY_MULT:-2.0}
            K8S_NAMESPACE=''${K8S_NAMESPACE:-default}

            AKASH_ENABLE=''${AKASH_ENABLE:-false}
            AKASH_MARGIN=''${AKASH_MARGIN:-0.90}
            AKASH_NAMESPACE=''${AKASH_NAMESPACE:-akash-services}

            GAMING_ENABLE=''${GAMING_ENABLE:-true}
            GAMING_GAMES="''${GAMING_GAMES:-}"

            log() {
                local level="''${1:-INFO}"
                shift
                local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
                echo "$msg" | tee -a "$LOG_FILE" >&2
            }

            log_debug() { log "DEBUG" "$@"; }
            log_info() { log "INFO" "$@"; }
            log_warn() { log "WARN" "$@"; }
            log_error() { log "ERROR" "$@"; }
            log_auction() { log "AUCTION" "$@" >&2; }

            update_metrics() {
                local winner=''${1:-none}
                local winning_bid=''${2:-0}
                local mining_bid=''${3:-0}
                local k8s_bid=''${4:-0}
                local akash_bid=''${5:-0}
                local gaming_active=''${6:-false}
                local auction_count=$(cat "$STATE_DIR/auction_count" 2>/dev/null || echo 0)

                local gpu_mem_free=$(gpu_memory_available)
                local gpu_mem_total=$(gpu_memory_total)
                local gpu_mem_util=$(gpu_utilization)

                {
                    echo "# HELP compute_market_auction_winner The current auction winner"
                    echo "# TYPE compute_market_auction_winner gauge"
                    echo "compute_market_auction_winner{winner=\"''${winner}\"} 1"
                    echo ""
                    echo "# HELP compute_market_winning_bid_usd The winning bid amount in USD"
                    echo "# TYPE compute_market_winning_bid_usd gauge"
                    echo "compute_market_winning_bid_usd ''${winning_bid}"
                    echo ""
                    echo "# HELP compute_market_bid_current Current bid by bidder type"
                    echo "# TYPE compute_market_bid_current gauge"
                    echo "compute_market_bid_current{bidder=\"mining\"} ''${mining_bid}"
                    echo "compute_market_bid_current{bidder=\"kubernetes\"} ''${k8s_bid}"
                    echo "compute_market_bid_current{bidder=\"akash\"} ''${akash_bid}"
                    echo "compute_market_bid_current{bidder=\"gaming\"} 999.99"
                    echo ""
                    echo "# HELP compute_market_gaming_active Whether gaming is currently active"
                    echo "# TYPE compute_market_gaming_active gauge"
                    echo "compute_market_gaming_active ''${gaming_active}"
                    echo ""
                    echo "# HELP compute_market_auction_total Total auctions run"
                    echo "# TYPE compute_market_auction_total counter"
                    echo "compute_market_auction_total ''${auction_count}"
                    echo ""
                    echo "# HELP compute_market_gpu_memory_free_mb GPU memory free in MB"
                    echo "# TYPE compute_market_gpu_memory_free_mb gauge"
                    echo "compute_market_gpu_memory_free_mb ''${gpu_mem_free}"
                    echo ""
                    echo "# HELP compute_market_gpu_memory_total_mb Total GPU memory in MB"
                    echo "# TYPE compute_market_gpu_memory_total_mb gauge"
                    echo "compute_market_gpu_memory_total_mb ''${gpu_mem_total}"
                    echo ""
                    echo "# HELP compute_market_gpu_utilization GPU memory utilization ratio (0-1)"
                    echo "# TYPE compute_market_gpu_utilization gauge"
                    echo "compute_market_gpu_utilization ''${gpu_mem_util}"
                } > "$STATE_DIR/metrics.prom"
            }

            bid_mining() {
                if [ "$MINING_ENABLE" != "true" ]; then
                    echo 0
                    return
                fi

                for service in $MINING_SERVICES; do
                    if systemctl is-active --quiet "$service"; then
                        echo "$MINING_HOURLY"
                        return
                    fi
                done

                echo "$MINING_HOURLY"
            }

            bid_kubernetes() {
                if [ "$K8S_ENABLE" != "true" ]; then
                    echo 0
                    return
                fi

                if ! command -v kubectl >/dev/null 2>&1; then
                    log_debug "kubectl not available"
                    echo 0
                    return
                fi

                if ! kubectl get nodes >/dev/null 2>&1; then
                    log_debug "Kubernetes cluster not accessible"
                    echo 0
                    return
                fi

                local hostname=$(hostname)
                local total_bid=0

                local gpu_pods=$(kubectl get pods --all-namespaces \
                    --field-selector=spec.nodeName="$hostname" \
                    -o jsonpath='{range .items[?(@.spec.containers[*].resources.limits.nvidia\\.com/gpu)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
                    2>/dev/null || echo "")

                if [ -z "$gpu_pods" ]; then
                    echo 0
                    return
                fi

                while IFS= read -r pod; do
                    [ -z "$pod" ] && continue
                    local namespace=$(echo "$pod" | cut -d'/' -f1)
                    local name=$(echo "$pod" | cut -d'/' -f2)

                    if kubectl get pod "$name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
                        local priority_class=$(kubectl get pod "$name" -n "$namespace" \
                            -o jsonpath='{.spec.priorityClassName}' 2>/dev/null || echo "")

                        local bid=$K8S_BASE_BID

                        if [[ "$priority_class" =~ (high|urgent|critical) ]]; then
                            bid=$(echo "$bid * $K8S_URGENCY_MULT" | bc)
                        fi

                        total_bid=$(echo "$total_bid + $bid" | bc)
                    fi
                done <<< "$gpu_pods"

                echo "$total_bid"
            }

            bid_akash() {
                if [ "$AKASH_ENABLE" != "true" ]; then
                    echo 0
                    return
                fi
                echo 0
            }

            check_gaming() {
                if [ "$GAMING_ENABLE" != "true" ]; then
                    echo "false"
                    return
                fi

                if command -v gamemoded >/dev/null 2>&1; then
                    if gamemoded -s >/dev/null 2>&1; then
                        log_debug "Gaming detected via GameMode signal"
                        echo "true"
                        return
                    fi
                    echo "false"
                    return
                fi

                if [ -z "$GAMING_GAMES" ]; then
                    echo "false"
                    return
                fi

                for game_pattern in $GAMING_GAMES; do
                    if pgrep -x "$game_pattern" >/dev/null 2>&1; then
                        log_debug "Gaming detected: process matching '$game_pattern'"
                        echo "true"
                        return
                    fi
                done

                echo "false"
            }

            gpu_memory_available() {
                if command -v nvidia-smi >/dev/null 2>&1; then
                    nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | \
                        awk '{s+=$1} END {print s}'
                else
                    echo "24000"
                fi
            }

            gpu_memory_total() {
                if command -v nvidia-smi >/dev/null 2>&1; then
                    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | \
                        awk '{s+=$1} END {print s}'
                else
                    echo "24000"
                fi
            }

            gpu_utilization() {
                local mem_free=$(gpu_memory_available)
                local mem_total=$(gpu_memory_total)

                if [ "$mem_total" -gt 0 ]; then
                    echo "scale=4; ($mem_total - $mem_free) / $mem_total" | bc
                else
                    echo "0.5"
                fi
            }

            run_auction() {
                local count=$(($(cat "$STATE_DIR/auction_count" 2>/dev/null || echo 0) + 1))
                echo "$count" > "$STATE_DIR/auction_count"

                local current_winner=$(cat "$STATE_DIR/current_winner" 2>/dev/null || echo "none")
                local gaming_active=$(check_gaming)

                if [ "$gaming_active" = "true" ]; then
                    log_auction "GAMING OVERRIDE - Gaming detected, pausing all GPU workloads"
                    update_metrics "gaming" 999.99 0 0 0 "true"
                    echo "gaming" > "$STATE_DIR/current_winner"
                    apply_gaming_profile
                    return
                fi

                local mining_bid=$(bid_mining)
                local k8s_bid=$(bid_kubernetes)
                local akash_bid=$(bid_akash)

                log_auction "Auction #$count - Mining: \$$mining_bid/hr | K8s: \$$k8s_bid/hr | Akash: \$$akash_bid/hr"

                local winner="mining"
                local winning_bid=$mining_bid

                if (( $(echo "$k8s_bid > $winning_bid" | bc -l) )); then
                    winner="kubernetes"
                    winning_bid=$k8s_bid
                fi

                if (( $(echo "$akash_bid > $winning_bid" | bc -l) )); then
                    winner="akash"
                    winning_bid=$akash_bid
                fi

                if [ "$winner" != "$current_winner" ]; then
                    log_auction "WINNER CHANGED: $current_winner → $winner (\$$winning_bid/hr)"
                    echo "$winner" > "$STATE_DIR/current_winner"
                    apply_winner_profile "$winner"
                else
                    log_debug "Winner unchanged: $winner (\$$winning_bid/hr)"
                fi

                update_metrics "$winner" "$winning_bid" "$mining_bid" "$k8s_bid" "$akash_bid" "false"
            }

            apply_gaming_profile() {
                log_info "Applying GAMING profile - all GPU workloads paused"
                pause_all_mining
            }

            apply_winner_profile() {
                local winner="''${1:-mining}"

                case "$winner" in
                    mining)
                        log_info "Applying MINING profile - resuming mining"
                        resume_mining
                        ;;
                    kubernetes)
                        log_info "Applying KUBERNETES profile - pausing mining"
                        pause_all_mining
                        ;;
                    akash)
                        log_info "Applying AKASH profile - pausing mining"
                        pause_all_mining
                        ;;
                    *)
                        log_warn "Unknown winner: $winner"
                        ;;
                esac
            }

            pause_all_mining() {
                for service in $MINING_SERVICES; do
                    if systemctl is-active --quiet "$service"; then
                        log_info "Pausing $service"
                        systemctl stop "$service" --runtime
                        echo "$service" >> "$STATE_DIR/paused_services"
                    fi
                done
            }

            resume_mining() {
                if [ -f "$STATE_DIR/paused_services" ]; then
                    while IFS= read -r service; do
                        [ -z "$service" ] && continue
                        log_info "Resuming $service"
                        systemctl start "$service"
                    done < "$STATE_DIR/paused_services"
                    rm -f "$STATE_DIR/paused_services"
                fi
            }

            start_metrics_server() {
                while true; do
                    {
                        echo "HTTP/1.1 200 OK"
                        echo "Content-Type: text/plain"
                        echo ""
                        cat "$STATE_DIR/metrics.prom" 2>/dev/null || echo "# No metrics yet"
                    } | nc -l -p "$PROMETHEUS_PORT" > /dev/null 2>&1 || true
                done &
            }

            main() {
                log_info "=== GPU Resource Marketplace Starting ==="
                log_info "State directory: $STATE_DIR"
                log_info "Auction interval: $AUCTION_INTERVAL seconds"

                echo "0" > "$STATE_DIR/auction_count"
                echo "none" > "$STATE_DIR/current_winner"
                update_metrics "none" 0 0 0 0 "false"

                start_metrics_server

                while true; do
                    run_auction
                    sleep "$AUCTION_INTERVAL"
                done
            }

            main "$@"
          ''}/bin/compute-market-engine";
        };
      };

      services.prometheus.scrapeConfigs = lib.mkIf config.services.compute-market.prometheus.enable [
        {
          job_name = "compute-market";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString config.services.compute-market.prometheus.port}" ];
            }
          ];
        }
      ];
    };
}
