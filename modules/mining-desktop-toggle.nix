{
  config,
  lib,
  pkgs,
  ...
}:
let
  mkMinerToggle = { name, deploy, ns ? "mining", icon, startTitle, startBody, stopTitle, stopBody }: let
    toggleScript = pkgs.writeShellScriptBin "toggle-${name}" ''
      set -euo pipefail
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      CURRENT=$(${lib.getExe pkgs.kubectl} get deploy "${deploy}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [ "$CURRENT" = "0" ]; then
        ${lib.getExe pkgs.kubectl} scale deploy "${deploy}" -n "${ns}" --replicas=1
        ${lib.getExe pkgs.libnotify} -i media-playback-start -u normal "${startTitle}" "${startBody}"
      else
        ${lib.getExe pkgs.kubectl} scale deploy "${deploy}" -n "${ns}" --replicas=0
        ${lib.getExe pkgs.libnotify} -i media-playback-pause -u normal "${stopTitle}" "${stopBody}"
      fi
    '';
    statusScript = pkgs.writeShellScriptBin "${name}-status" ''
      set -euo pipefail
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      CURRENT=$(${lib.getExe pkgs.kubectl} get deploy "${deploy}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [ "$CURRENT" = "0" ]; then echo "paused"; else echo "running"; fi
    '';
    desktopEntry = pkgs.makeDesktopItem {
      desktopName = "Toggle ${name}";
      name = "toggle-${name}";
      comment = "Pause/resume ${name}";
      exec = "${toggleScript}/bin/toggle-${name}";
      icon = icon;
      terminal = false;
      type = "Application";
      categories = [ "System" "Utility" ];
    };
  in [ toggleScript statusScript desktopEntry ];

  miners = [
    {
      name = "3090-miner";
      deploy = "gpu-miner-zephyr";
      icon = "nvidia-settings";
      startTitle = "⛏ Mining resumed";
      startBody = "RTX 3090 lolMiner started";
      stopTitle = "⏸ Mining paused";
      stopBody = "RTX 3090 lolMiner stopped";
    }
    {
      name = "3060ti-miner";
      deploy = "gpu-miner-zephyr-3060ti";
      icon = "nvidia-settings";
      startTitle = "⛏ Mining resumed";
      startBody = "RTX 3060 Ti lolMiner started";
      stopTitle = "⏸ Mining paused";
      stopBody = "RTX 3060 Ti lolMiner stopped";
    }
    {
      name = "xmrig-proxy";
      deploy = "xmrig-proxy";
      icon = "cpu";
      startTitle = "⛏ XMRig resumed";
      startBody = "CPU mining proxy started";
      stopTitle = "⏸ XMRig paused";
      stopBody = "CPU mining proxy stopped";
    }
  ];

  allPackages = builtins.concatLists (map mkMinerToggle miners);
in
{
  config = lib.mkIf (config.networking.hostName == "zephyr") {
    environment.systemPackages = allPackages;
    environment.pathsToLink = [ "/share/applications" ];
  };
}
