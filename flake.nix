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
        lolminerPkg = pkgs.callPackage ./packages/lolminer.nix { };
      in
      {
        packages = {
          xmrig = pkgs.callPackage ./packages/xmrig.nix { };
          lolminer = lolminerPkg;

          xmrig-alpine-image = pkgs.callPackage ./container-images/xmrig-alpine.nix { };
          xmrig-proxy-alpine-image = pkgs.callPackage ./container-images/xmrig-proxy-alpine.nix { };

          lolminer-image = pkgs.dockerTools.buildImage {
            name = "lolminer";
            tag = "1.98a-nixos";
            copyToRoot = pkgs.buildEnv {
              name = "lolminer-root";
              paths = [
                lolminerPkg
                pkgs.bash
                pkgs.coreutils
                pkgs.cacert
              ];
              pathsToLink = [
                "/bin"
                "/etc"
                "/lib"
              ];
            };
            config = {
              Entrypoint = [ "/bin/lolMiner" ];
              Cmd = [ ];
              ExposedPorts = {
                "4068/tcp" = { };
              };
              Env = [
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                "PATH=/bin"
                "GPU_MAX_HEAP_SIZE=100"
                "GPU_MAX_ALLOC_PERCENT=100"
              ];
            };
          };

          lolminer-amd-image =
            let
              glibc = pkgs.glibc;
              rootFs = pkgs.runCommand "lolminer-amd-root" { } ''
                mkdir -p $out/bin $out/etc $out/lib $out/lib64 $out/tmp $out/run/opengl-driver/lib $out/etc/OpenCL/vendors
                cp ${lolminerPkg}/bin/.lolMiner-wrapped $out/bin/.lolMiner-wrapped
                chmod +x $out/bin/.lolMiner-wrapped
                echo '#! /bin/sh -e' > $out/bin/lolMiner
                echo 'LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$LD_LIBRARY_PATH:' >> $out/bin/lolMiner
                echo 'LD_LIBRARY_PATH=/lib:$LD_LIBRARY_PATH' >> $out/bin/lolMiner
                echo 'export LD_LIBRARY_PATH' >> $out/bin/lolMiner
                echo 'exec /bin/.lolMiner-wrapped "$@"' >> $out/bin/lolMiner
                chmod +x $out/bin/lolMiner
                for pkg in ${pkgs.bash} ${pkgs.coreutils}; do
                  if [ -d "$pkg/bin" ]; then
                    for bin in $pkg/bin/*; do
                      [ -e "$bin" ] && ln -sf "$bin" $out/bin/
                    done
                  fi
                  if [ -d "$pkg/lib" ]; then
                    cp -rL "$pkg/lib"/* $out/lib/ || echo "Warning: some libs from $pkg failed to copy"
                  fi
                done
                mkdir -p $out/etc/ssl/certs
                ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/
                for pkg in ${pkgs.rocmPackages.clr} ${pkgs.rocmPackages.clr.icd} ${pkgs.mesa.opencl}; do
                  if [ -d "$pkg/lib" ]; then
                    cp -rL "$pkg/lib"/* $out/lib/ || echo "Warning: some libs from $pkg failed to copy"
                  fi
                  if [ -d "$pkg/lib" ]; then
                    cp -rL "$pkg/lib"/* $out/run/opengl-driver/lib/ || echo "Warning: some libs from $pkg failed to copy"
                  fi
                  if [ -d "$pkg/etc" ]; then
                    cp -r $pkg/etc/* $out/etc/ || echo "Warning: some etc files from $pkg failed to copy"
                  fi
                done
                rm -f $out/etc/OpenCL/vendors/rusticl.icd
                cp -rL ${glibc}/lib/* $out/lib/ || echo "Warning: some glibc libs failed to copy"
                mkdir -p $out/lib64
                cp -rL ${glibc}/lib/* $out/lib64/ || echo "Warning: some glibc libs failed to copy to lib64"
                rm -f $out/etc/OpenCL/vendors/amdocl64.icd
                echo "/lib/libamdocl64.so" > $out/etc/OpenCL/vendors/amdocl64.icd
              '';
            in
            pkgs.dockerTools.buildImage {
              name = "lolminer-amd";
              tag = "1.98a-nixos";
              copyToRoot = rootFs;
              config = {
                Entrypoint = [ "/bin/lolMiner" ];
                Cmd = [ ];
                ExposedPorts = {
                  "4069/tcp" = { };
                };
                Env = [
                  "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                  "OCL_ICD_VENDORS=/etc/OpenCL/vendors"
                  "LD_LIBRARY_PATH=/lib"
                  "GPU_MAX_HEAP_SIZE=100"
                  "GPU_MAX_ALLOC_PERCENT=100"
                ];
                Labels = {
                  "version" = "1.98a";
                  "description" = "lolMiner NixOS container with AMD OpenCL support";
                };
              };
            };

          xmrig-nixos-image = pkgs.dockerTools.buildLayeredImage {
            name = "xmrig-nixos";
            tag = "latest";
            contents = [
              pkgs.xmrig
              pkgs.bash
              pkgs.coreutils
            ];
            config = {
              Entrypoint = [ "${pkgs.xmrig}/bin/xmrig" ];
              Env = [ "PATH=/bin" ];
              Labels = {
                "description" = "XMRig NixOS container with GLIBC compatibility";
              };
            };
          };

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
