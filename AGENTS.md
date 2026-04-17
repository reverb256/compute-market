# Compute Market - AGENTS.md

## Project Overview
GPU time-slicing system for NixOS. Mines crypto when idle, stops for gaming. Auction-based GPU allocation between mining, K8s, Akash, and gaming workloads.

## Tech Stack
- NixOS modules (Nix)
- Shell scripts (bash)
- C++ (gpu-proxy-cpp)
- Python (mining-exporter, xmrig-metrics)
- Grafana dashboards (JSON + Nix helper)
- Miners: XMRig (CPU/RandomX), lolMiner (GPU/CR29)

## Key Entry Points
- `modules/compute-market.nix` - Core auction engine (systemd service + shell script)
- `modules/mining.nix` - Mining services (lolMiner + XMRig systemd services)
- `modules/gaming-mining-coordinator.nix` - Gaming detection + K8s scaling
- `flake.nix` - Nix flake: nixosModules.default, packages, devShells

## Module Dependencies
- `mining.nix` creates the `mining` user/group and `mining.slice`
- `dual-xmrig.nix` depends on `mining.nix` (sets `services.mining.enable = true`)
- `gaming-mining-coordinator.nix` requires `gaming-detection` and `k3s` services (external)
- `mining-exporter.nix` is host-aware (zephyr, nexus, forge, sentry configs)
- `mining-desktop-toggle.nix` is host-specific (zephyr only)
- `gpu-proxy-cpp.nix` builds from `gpu-proxy-cpp/` subdirectory

## External Dependencies
- NVIDIA drivers (nvidia-smi) for GPU monitoring
- AMD ROCm (rocm-smi) for AMD power limits
- Kubernetes/kubectl for K8s bidder and mining coordination
- GameMode (gamemoded) for gaming detection
- Prometheus + Grafana for monitoring
- Agenix for secret management (API tokens)

## Testing
```bash
nix flake check          # Validate flake
nix build .#xmrig        # Build XMRig package
nix build .#lolminer     # Build lolMiner package
nix build .#gpu-proxy-cpp  # Build GPU proxy
nix develop              # Enter dev shell
```

## Important Notes
- `mining-proxy.nix` has `lib.fakeSha256` - needs real hash before building
- `mining-exporter.nix` has a bug: metrics loop only runs once (http server blocks)
- Container images use static-linked xmrig binaries from kryptex-miners-org
- Original sources at `/etc/nixos/` are NOT to be modified (this is an extraction)
