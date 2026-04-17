# Compute Market

GPU time-slicing system that mines cryptocurrency when idle and stops for gaming. A NixOS-based GPU resource marketplace with auction-based allocation across mining, Kubernetes workloads, Akash Network leases, and gaming.

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │          Kryptex Pool(s)             │
                    │  (xtm-rx-us/eu, xtm-c29-us/eu)      │
                    └──────┬──────────────────┬────────────┘
                           │                  │
                    RandomX (CPU)      CR29 (GPU)
                           │                  │
                ┌──────────▼──────────┐  ┌────▼──────────────────┐
                │  XMRig Proxy        │  │  GPU Proxy C++        │
                │  (Zephyr :3333)     │  │  (Forge :3334)        │
                └──────────┬──────────┘  └────┬──────────────────┘
                           │                  │
              ┌────────────┼─────────┐    ┌───┼──────────┐
              │            │         │    │   │          │
         Zephyr-CPU   Nexus-CPU  Sentry-CPU  Forge-GPU  K8s-GPU
         (flexible)                        (bare-metal)
```

## Components

### Core Module (`services.compute-market`)
GPU auction engine that bids GPU time between competing workloads:
- **Mining bidder** - Baseline revenue (~$0.014/hr/GPU)
- **Kubernetes bidder** - Higher bid for K8s GPU workloads ($2.50+/hr)
- **Akash bidder** - Market-rate bids for Akash Network leases
- **Gaming override** - Always wins when gaming is detected, pauses all mining

### Mining Services (`services.mining`)
- **lolMiner** - NVIDIA/AMD GPU mining (CR29/Cuckaroo29 algorithm)
- **XMRig** - CPU mining (RandomX algorithm)
- **Dual XMRig** - Always-on + flexible instances (flexible pauses during gaming)
- **GPU power management** - Per-GPU power limits and memory clock locking

### Proxy Infrastructure
- **XMRig Proxy** - Stratum proxy for CPU mining aggregation
- **GPU Proxy C++** - High-performance stratum proxy for GPU mining
- **Mining Proxy** - Universal Python stratum proxy with failover

### Coordination
- **Gaming-Mining Coordinator** - Detects gaming via GameMode/process monitoring, scales K8s mining deployments to 0 with hysteresis
- **Auto-Gaming Detection** - Scans system for installed games and GPU-bound processes

### Monitoring
- **Mining Exporter** - Prometheus metrics from lolMiner and XMRig APIs
- **XMRig Metrics** - Node-exporter textfile collector for XMRig JSON API
- **Grafana Dashboards** - Real-time mining operations and marketplace auction status
- **Plasma Plasmoid** - KDE Plasma widget for multi-node mining metrics

## Quick Start

### As a NixOS module (flake input)

```nix
# flake.nix
{
  inputs.compute-market.url = "github:yourorg/compute-market";

  outputs = { nixpkgs, compute-market, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        compute-market.nixosModules.default
        {
          services.compute-market.enable = true;
          services.compute-market.bidders.mining.enable = true;
          services.compute-market.bidders.gaming.enable = true;

          services.mining.enable = true;
          services.mining.xmrig.enable = true;
          services.mining.xmrig.pool = "xtm-rx-us.kryptex.network:8038";
          services.mining.xmrig.wallet = "your-wallet-address";
        }
      ];
    };
  };
}
```

### Standalone packages

```bash
# Build miners
nix build .#xmrig
nix build .#lolminer

# Build container images
nix build .#xmrig-alpine-image
nix build .#xmrig-proxy-alpine-image

# Build GPU proxy
nix build .#gpu-proxy-cpp
```

### Development shell

```bash
nix develop
```

## NixOS Module Options

### `services.compute-market`
| Option | Default | Description |
|--------|---------|-------------|
| `enable` | false | Enable GPU marketplace auction engine |
| `auctionInterval` | 30 | Seconds between auctions |
| `stateDirectory` | `/run/compute-market` | State directory |
| `logFile` | `/var/log/compute-market.log` | Log file path |
| `bidders.mining.hourlyRevenue` | 0.014 | USD/hr baseline mining revenue |
| `bidders.kubernetes.baseBid` | 2.50 | USD/hr base K8s bid |
| `bidders.akash.profitMargin` | 0.90 | Market rate percentage to bid |
| `bidders.gaming.enable` | true | Gaming always-wins override |
| `prometheus.port` | 9200 | Metrics exporter port |

### `services.mining`
| Option | Default | Description |
|--------|---------|-------------|
| `enable` | false | Enable mining services |
| `lolminer.nvidia.enable` | false | NVIDIA GPU mining |
| `lolminer.amd.enable` | false | AMD GPU mining |
| `xmrig.enable` | false | CPU mining |
| `xmrig.pool` | `xtm-rx-us.kryptex.network:8038` | Mining pool |
| `xmrig.threads` | 16 | CPU threads |

### `services.gaming-mining-coordinator`
| Option | Default | Description |
|--------|---------|-------------|
| `enable` | false | Enable gaming-mining coordination |
| `checkInterval` | 10 | Gaming state check interval (seconds) |
| `hysteresisCycles` | 3 | Checks before resuming mining |

## Prometheus Metrics

- `compute_market_auction_winner` - Current auction winner label
- `compute_market_winning_bid_usd` - Winning bid in USD/hr
- `compute_market_bid_current{bidder=}` - Per-bidder current bid
- `compute_market_gaming_active` - Gaming detection (0/1)
- `compute_market_auction_total` - Total auctions run
- `mining_lolminer_hashrate_total` - GPU hashrate
- `mining_xmrig_hashrate_total` - CPU hashrate

## Directory Structure

```
compute-market/
├── flake.nix                  # Flake with nixosModules, packages, devShells
├── README.md                  # This file
├── AGENTS.md                  # Agent context
├── modules/
│   ├── compute-market.nix     # Core auction engine module
│   ├── mining.nix             # lolMiner (NVIDIA/AMD) + XMRig
│   ├── dual-xmrig.nix         # Always-on + flexible XMRig instances
│   ├── xmrig-proxy.nix        # CPU stratum proxy
│   ├── mining-proxy.nix       # Universal Python stratum proxy
│   ├── gpu-proxy-cpp.nix      # C++ GPU stratum proxy
│   ├── gaming-mining-coordinator.nix  # Gaming detection + K8s scaling
│   ├── mining-exporter.nix    # Prometheus metrics exporter
│   ├── xmrig-metrics.nix      # XMRig textfile collector
│   ├── mining-desktop-toggle.nix      # KDE desktop toggle
│   ├── mining-plasmoid.nix    # Plasma widget
│   └── auto-gaming-detection.sh       # Game auto-detection script
├── packages/
│   ├── xmrig.nix              # XMRig CPU miner package
│   └── lolminer.nix           # lolMiner GPU miner package
├── container-images/
│   ├── xmrig-alpine.nix       # XMRig container image
│   └── xmrig-proxy-alpine.nix # XMRig proxy container image
├── dashboards/
│   ├── grafana-dashboard.json # GPU Marketplace Grafana dashboard
│   └── mining.nix             # Mining Operations Grafana dashboard
└── gpu-proxy-cpp/             # C++ GPU mining proxy source
    ├── CMakeLists.txt
    ├── main.cpp
    └── src/
```
