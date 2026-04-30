{
  config,
  lib,
  pkgs,
  ...
}:
let
  kubectl = lib.getExe pkgs.kubectl;
  notify = lib.getExe pkgs.libnotify;

  # Toggle between miner and llama on the 3090.
  # Scales one down, waits for pod termination, scales the other up.
  toggle-3090 = pkgs.writeShellScriptBin "toggle-3090-miner" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    MINER_DEPLOY="gpu-miner-zephyr"
    MINER_NS="mining"
    LLAMA_DEPLOY="llama-server-zephyr"
    LLAMA_NS="ai-inference"
    TIMEOUT=120

    miner_replicas=$(${kubectl} get deploy "$MINER_DEPLOY" -n "$MINER_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    llama_replicas=$(${kubectl} get deploy "$LLAMA_DEPLOY" -n "$LLAMA_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    if [ "$miner_replicas" != "0" ]; then
      # Miner is running → stop it, start llama
      echo "Stopping miner..."
      ${notify} -i media-playback-pause -u normal "⏸ Mining paused" "Scaling down $MINER_DEPLOY..."
      ${kubectl} scale deploy "$MINER_DEPLOY" -n "$MINER_NS" --replicas=0

      # Wait for miner pod to terminate
      echo "Waiting for miner pod to terminate (timeout ''${TIMEOUT}s)..."
      elapsed=0
      while [ $elapsed -lt $TIMEOUT ]; do
        count=$(${kubectl} get pods -n "$MINER_NS" -l app="$MINER_DEPLOY" --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$count" -eq 0 ]; then
          echo "Miner pod terminated after ''${elapsed}s"
          break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
      done

      if [ $elapsed -ge $TIMEOUT ]; then
        ${notify} -i dialog-error -u critical "⚠ Timeout" "Miner pod did not terminate in ''${TIMEOUT}s"
        exit 1
      fi

      # Give GPU a moment to release VRAM
      sleep 2

      echo "Starting llama server..."
      ${kubectl} scale deploy "$LLAMA_DEPLOY" -n "$LLAMA_NS" --replicas=1
      ${notify} -i applications-science -u normal "🧠 Llama starting" "Qwen3.6-35B loading on RTX 3090..."

    elif [ "$llama_replicas" != "0" ]; then
      # Llama is running → stop it, start miner
      echo "Stopping llama server..."
      ${notify} -i media-playback-pause -u normal "⏸ Llama stopping" "Scaling down $LLAMA_DEPLOY..."
      ${kubectl} scale deploy "$LLAMA_DEPLOY" -n "$LLAMA_NS" --replicas=0

      # Wait for llama pod to terminate
      echo "Waiting for llama pod to terminate (timeout ''${TIMEOUT}s)..."
      elapsed=0
      while [ $elapsed -lt $TIMEOUT ]; do
        count=$(${kubectl} get pods -n "$LLAMA_NS" -l app="$LLAMA_DEPLOY" --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$count" -eq 0 ]; then
          echo "Llama pod terminated after ''${elapsed}s"
          break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
      done

      if [ $elapsed -ge $TIMEOUT ]; then
        ${notify} -i dialog-error -u critical "⚠ Timeout" "Llama pod did not terminate in ''${TIMEOUT}s"
        exit 1
      fi

      # Give GPU a moment to release VRAM
      sleep 2

      echo "Starting miner..."
      ${kubectl} scale deploy "$MINER_DEPLOY" -n "$MINER_NS" --replicas=1
      ${notify} -i media-playback-start -u normal "⛏ Mining resumed" "bzminer started on RTX 3090"

    else
      # Neither running → start llama by default
      echo "Neither running. Starting llama server..."
      ${kubectl} scale deploy "$LLAMA_DEPLOY" -n "$LLAMA_NS" --replicas=1
      ${notify} -i applications-science -u normal "🧠 Llama starting" "Qwen3.6-35B loading on RTX 3090..."
    fi
  '';

  # Status checker: reports which workload is active on the 3090
  status-3090 = pkgs.writeShellScriptBin "3090-status" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    miner=$(${kubectl} get deploy gpu-miner-zephyr -n mining -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    llama=$(${kubectl} get deploy llama-server-zephyr -n ai-inference -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    if [ "$miner" != "0" ]; then
      echo "mining"
    elif [ "$llama" != "0" ]; then
      echo "llama"
    else
      echo "idle"
    fi
  '';

  desktop-entry = pkgs.makeDesktopItem {
    desktopName = "Toggle 3090 Miner/Llama";
    name = "toggle-3090-miner";
    comment = "Swap between bzminer and Qwen3.6-35B llama on RTX 3090";
    exec = "${toggle-3090}/bin/toggle-3090-miner";
    icon = "nvidia-settings";
    terminal = false;
    type = "Application";
    categories = [ "System" "Utility" ];
  };
in
{
  config = lib.mkIf (config.networking.hostName == "zephyr") {
    environment.systemPackages = [ toggle-3090 status-3090 desktop-entry ];
    environment.pathsToLink = [ "/share/applications" ];
  };
}
