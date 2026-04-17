{
  description = "Compute Market - GPU time-slicing system that mines crypto when idle and stops for gaming";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
    in
    {
      nixosModules.default = {
        imports = [
          # Core compute-market auction engine
          ./modules/compute-market.nix

          # Mining services
          ./modules/mining.nix
          ./modules/dual-xmrig.nix
          ./modules/xmrig-proxy.nix
          ./modules/mining-proxy.nix
          # gpu-proxy-cpp moved to standalone gpu-proxy flake

          # Coordination and monitoring
          ./modules/gaming-mining-coordinator.nix
          ./modules/mining-exporter.nix
          ./modules/xmrig-metrics.nix
          ./modules/mining-desktop-toggle.nix
        ];
      };

      kubernetesModules.default = {
        imports = [
          ./kubernetes/mining.nix
          ./kubernetes/gpu-miners.nix
        ];
      };
    }
    // flake-utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      in
      {
        packages = {
          xmrig = pkgs.callPackage ./packages/xmrig.nix { };
          lolminer = pkgs.callPackage ./packages/lolminer.nix { };

          xmrig-alpine-image = pkgs.callPackage ./container-images/xmrig-alpine.nix { };
          xmrig-proxy-alpine-image = pkgs.callPackage ./container-images/xmrig-proxy-alpine.nix { };

          gpu-proxy-cpp = pkgs.stdenv.mkDerivation rec {
            pname = "gpu-proxy-cpp";
            version = "2.0.0";

            src = ./gpu-proxy-cpp;

            nativeBuildInputs = with pkgs; [
              cmake
              pkg-config
            ];
            buildInputs = with pkgs; [
              openssl
              nlohmann_json
            ];

            cmakeFlags = [ "-DCMAKE_BUILD_TYPE=Release" ];

            preConfigure = ''
              export NIX_CFLAGS_COMPILE="-I${pkgs.nlohmann_json}/include/nlohmann $NIX_CFLAGS_COMPILE"
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp gpu-proxy $out/bin/
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nixpkgs-fmt
            nil
            jq
            curl
            bc
          ];

          shellHook = ''
            echo "Compute Market development shell"
            echo "  Packages: xmrig, lolminer, gpu-proxy-cpp"
            echo "  Modules:  compute-market, mining, dual-xmrig, xmrig-proxy"
            echo "  Dashboards: grafana-dashboard.json, mining.nix"
          '';
        };
      }
    );
}
