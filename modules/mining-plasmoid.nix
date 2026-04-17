{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.programs.mining-plasmoid;

  plasmoidName = "org.revervos.mining-monitor";
  plasmoidSrc = ../plasmoids/mining-monitor;
in
{
  options.programs.mining-plasmoid = {
    enable = lib.mkEnableOption "Mining Monitor Plasma Plasmoid - Multi-node GPU/CPU monitor";

    prometheusUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9090";
      description = "Prometheus server URL for mining metrics";
    };

    refreshInterval = lib.mkOption {
      type = lib.types.int;
      default = 10000;
      description = "Refresh interval in milliseconds";
    };

    clusterNodes = lib.mkOption {
      type = lib.types.str;
      default = "zephyr,nexus,forge,sentry";
      description = "Comma-separated list of cluster node hostnames to monitor";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.runCommand "mining-monitor-plasmoid" { } ''
        mkdir -p $out/share/plasma/plasmoids/${plasmoidName}/config
        cp -r ${plasmoidSrc}/* $out/share/plasma/plasmoids/${plasmoidName}/

        cat > $out/share/plasma/plasmoids/${plasmoidName}/config/main.xml <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <kcfg xmlns="http://www.kde.org/standards/kcfg/1.0"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://www.kde.org/standards/kcfg/1.0
              http://www.kde.org/standards/kcfg/1.0/kcfg.xsd">
          <group name="General">
            <entry name="prometheusUrl" type="String">
              <default>${cfg.prometheusUrl}</default>
            </entry>
            <entry name="refreshInterval" type="Int">
              <default>${toString cfg.refreshInterval}</default>
            </entry>
            <entry name="clusterNodes" type="String">
              <default>${cfg.clusterNodes}</default>
            </entry>
          </group>
        </kcfg>
        EOF
      '')
    ];
  };
}
