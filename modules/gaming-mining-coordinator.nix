{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gaming-mining-coordinator;
  inherit (lib)
    mkEnableOption
    mkOption
    types
    mkIf
    mkMerge
    ;
  inherit (lib) mkOptionDefault;

  defaultMiningDeployments = {
    zephyr = [ "gpu-miner-zephyr" ];
    nexus = [ "gpu-miner-nexus" ];
    forge = [
      "gpu-miner-forge-nvidia-0"
      "gpu-miner-forge-nvidia-1"
    ];
  };
in
{
  options.services.gaming-mining-coordinator = {
    enable = mkEnableOption "Gaming-Mining Coordinator - pause K8s mining when gaming detected";

    checkInterval = mkOption {
      type = types.int;
      default = 10;
      description = "Check interval in seconds for gaming state";
    };

    hysteresisCycles = mkOption {
      type = types.int;
      default = 3;
      description = "Number of consecutive 'no gaming' checks before resuming mining";
    };

    miningNamespace = mkOption {
      type = types.str;
      default = "mining";
      description = "Kubernetes namespace where mining deployments exist";
    };

    deployments = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "List of mining deployment names to pause/resume on this node";
    };

    logFile = mkOption {
      type = types.str;
      default = "/var/log/gaming-mining-coordinator.log";
      description = "Path to log file";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.gaming-detection.enable or false;
        message = "gaming-mining-coordinator requires services.gaming-detection.enable = true";
      }
      {
        assertion = config.services.k3s-cluster.enable or false;
        message = "gaming-mining-coordinator requires K3s cluster (services.k3s-cluster.enable = true)";
      }
    ];

    systemd.services.gaming-mining-coordinator = {
      description = "Gaming-Mining Coordinator - pause K8s mining during gaming";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "k3s.service"
        "gaming-detection.service"
      ];
      wants = [ "gaming-detection.service" ];
      path = with pkgs; [
        kubernetes
        bash
        coreutils
      ];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";
        Environment = "PATH=${
          lib.makeBinPath (
            with pkgs;
            [
              kubernetes
              coreutils
            ]
          )
        }:/run/current-system/sw/bin";
        ExecStart =
          let
            script = pkgs.writeShellScript "gaming-mining-coordinator" ''

              set -euo pipefail

              LOG_FILE="${cfg.logFile}"
              STATE_FILE="/run/gaming-detection/gaming_state"
              CHECK_INTERVAL="${toString cfg.checkInterval}"
              HYSTERESIS_CYCLES="${toString cfg.hysteresisCycles}"
              MINING_NAMESPACE="${cfg.miningNamespace}"
              DEPLOYMENTS="${lib.concatStringsSep " " cfg.deployments}"

              log() {
                  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [coordinator] $*" >> "$LOG_FILE"
              }

              read_gaming_state() {
                  if [[ ! -f "$STATE_FILE" ]]; then
                      echo "0"
                      return 1
                  fi
                  source "$STATE_FILE"
                  echo "$GAMING_ACTIVE"
              }

              read_detection_method() {
                  if [[ ! -f "$STATE_FILE" ]]; then
                      echo "unknown"
                      return 1
                  fi
                  source "$STATE_FILE"
                  echo "$DETECTION_METHOD"
              }

              scale_deployment() {
                  local deployment=$1
                  local replicas=$2
                  
                  if ! kubectl get deployment "$deployment" -n "$MINING_NAMESPACE" &>/dev/null; then
                      log "Deployment $deployment not found in namespace $MINING_NAMESPACE - skipping"
                      return 0
                  fi
                  
                  if kubectl scale deployment "$deployment" -n "$MINING_NAMESPACE" --replicas="$replicas" &>/dev/null; then
                      log "Scaled deployment $deployment to $replicas replicas"
                      return 0
                  else
                      log "Failed to scale deployment $deployment"
                      return 1
                  fi
              }

              pause_mining() {
                  log "=== PAUSING MINING (gaming detected) ==="
                  
                  for deployment in $DEPLOYMENTS; do
                      scale_deployment "$deployment" 0
                  done
                  
                  log "Mining paused on $(hostname)"
              }

              resume_mining() {
                  log "=== RESUMING MINING (gaming ended) ==="
                  
                  for deployment in $DEPLOYMENTS; do
                      scale_deployment "$deployment" 1
                  done
                  
                  log "Mining resumed on $(hostname)"
              }

              main() {
                  local was_gaming=0
                  local hysteresis_count=0

                  log "Starting Gaming-Mining Coordinator"
                  log "Monitoring deployments: $DEPLOYMENTS"
                  log "State file: $STATE_FILE"
                  log "Check interval: $${CHECK_INTERVAL}s"
                  log "Hysteresis cycles: $${HYSTERESIS_CYCLES}"

                  while true; do
                      local gaming_state
                      gaming_state=$(read_gaming_state) || gaming_state="0"
                      local detection_method
                      detection_method=$(read_detection_method) || detection_method="unknown"
                      
                      local is_gaming=0
                      if [[ "$gaming_state" == "1" ]]; then
                          is_gaming=1
                      fi

                      if [[ "$was_gaming" == "0" ]] && [[ "$is_gaming" == "1" ]]; then
                          log "Gaming START detected (method: $detection_method)"
                          pause_mining
                          was_gaming=1
                          hysteresis_count=0

                      elif [[ "$was_gaming" == "1" ]] && [[ "$is_gaming" == "0" ]]; then
                          log "Gaming END detected - starting hysteresis countdown"
                          hysteresis_count=1

                      elif [[ "$was_gaming" == "1" ]] && [[ "$is_gaming" == "0" ]] && [[ "$hysteresis_count" -gt 0 ]]; then
                          if [[ "$hysteresis_count" -ge "$HYSTERESIS_CYCLES" ]]; then
                              log "Hysteresis complete - resuming mining"
                              resume_mining
                              was_gaming=0
                              hysteresis_count=0
                          else
                              log "Hysteresis countdown: $hysteresis_count/$HYSTERESIS_CYCLES"
                              hysteresis_count=$((hysteresis_count + 1))
                          fi

                      elif [[ "$was_gaming" == "0" ]] && [[ "$is_gaming" == "0" ]] && [[ "$hysteresis_count" -gt 0 ]]; then
                          log "Gaming resumed during hysteresis - staying paused"
                          hysteresis_count=0
                      fi

                      sleep "$CHECK_INTERVAL"
                  done
              }

              main
            '';
          in
          "${script}/bin/gaming-mining-coordinator";
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/gaming-detection 0755 root root -"
    ];
  };
}
