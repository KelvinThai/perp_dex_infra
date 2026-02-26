# Custom Perp DEX — Kubernetes Deployment Guide

## Architecture Overview

```
                        ┌─────────────────────┐
                        │    Ingress (nginx)   │
                        │  dex.yourdomain.com  │
                        └──┬──────┬──────┬─────┘
                           │      │      │
              ┌────────────┘      │      └────────────┐
              ▼                   ▼                    ▼
     ┌────────────────┐  ┌──────────────┐   ┌────────────────┐
     │  Frontend (3000)│  │ DLOB HTTP    │   │ DLOB WS        │
     │  Next.js        │  │ API (6969)   │   │ Manager (6970) │
     └────────────────┘  └──────┬───────┘   └───────┬────────┘
                                │                    │
                         ┌──────▼────────────────────▼──┐
                         │         Redis (6379)          │
                         └──────────────▲───────────────┘
                                        │
                              ┌─────────┴─────────┐
                              │  DLOB Publisher    │
                              │  (background)      │
                              └─────────┬──────────┘
                                        │
                    ┌───────────────────▼───────────────────┐
                    │          Solana Devnet (RPC)           │
                    └──▲────────▲────────▲────────▲────────┘
                       │        │        │        │
              ┌────────┘  ┌─────┘  ┌─────┘  ┌─────┘
              │           │        │        │
     ┌────────────┐ ┌─────────┐ ┌──────┐ ┌──────────┐
     │ Keeper Bots│ │ Oracle  │ │Market│ │ Drift    │
     │ (5 bots)   │ │ Updater │ │Maker │ │ Program  │
     └────────────┘ └─────────┘ └──────┘ └──────────┘
```

## Components Summary

| Component | Image | Replicas | Ports | Secrets Needed |
|-----------|-------|----------|-------|----------------|
| Redis | redis:7-alpine | 1 | 6379 | none |
| DLOB HTTP API | custom-dlob:latest | 1 | 6969, 9464 | none |
| DLOB Publisher | custom-dlob:latest | 1 | 8080, 9465 | none |
| DLOB WS Manager | custom-dlob:latest | 1 | 6970, 9467 | none |
| Keeper Bots | custom-keeper:latest | 1 | 8888, 9471-9475 | keeper-private-key |
| Oracle Updater | custom-perp-bots:latest | 1 | none | admin-keypair |
| Market Maker | custom-perp-bots:latest | 1 | none | admin-keypair |
| Frontend | custom-frontend:latest | 1 | 3000 | none |

---

## Prerequisites

### Hardware
- 1+ nodes, minimum 4 CPU / 16 GB RAM / 100 GB SSD
- Public IP for ingress (or load balancer)
- Outbound internet access (Solana RPC, Pyth Hermes)

### Software
- Kubernetes 1.28+ (k3s recommended for single-node: `curl -sfL https://get.k3s.io | sh -`)
- kubectl configured
- Docker or containerd for building images
- A container registry (Docker Hub, or local registry)
- git, node 20+, yarn, rust 1.79.0 (for program builds only)

### Accounts & Keys
- **Admin keypair** (`keys/admin-keypair.json`) — signs oracle updates + market maker orders
- **Keeper keypair** — from `KEEPER_PRIVATE_KEY` env var, signs keeper bot transactions
- **QuikNode RPC** endpoint (or any Solana devnet RPC)
- **Solana program** already deployed at `6prdU12bH7QLTHoNPhA3RF1yzSjrduLQg45JQgCMJ1ko`

---

## Step 1: Solana Program (Already Deployed)

The Drift fork program is already deployed on devnet. For reference, the build + deploy process:

```bash
# Build (from ~/protocol-v2)
export C_INCLUDE_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include"
RUSTFLAGS="-C opt-level=z" cargo build-sbf \
  --manifest-path programs/drift/Cargo.toml \
  --tools-version v1.42 --arch sbfv1 \
  --sbf-out-dir target/deploy

# Deploy (~39 SOL needed for buffer rent, returned after deploy)
solana program deploy target/deploy/drift.so \
  --program-id keys/program-keypair.json \
  --keypair keys/admin-keypair.json \
  --url https://api.devnet.solana.com
```

**On-chain state** (already initialized):
- Program: `6prdU12bH7QLTHoNPhA3RF1yzSjrduLQg45JQgCMJ1ko`
- Admin: `7XAMFnYGKtJDqATNycQ6JQ7CwvFazrrtmmwn1UHSLQGr`
- Markets: SOL-PERP (0), BTC-PERP (1), ETH-PERP (2), TEAM-PERP (3), USDC spot (0)
- Oracles: Pyth PYTH_PULL for 0-2, PrelaunchOracle for 3

**No K8s deployment needed for the program itself** — it lives on Solana.

---

## Step 2: Build the SDK

All downstream services depend on the local SDK. Build it first:

```bash
cd ~/protocol-v2/sdk
yarn install --ignore-engines
yarn build
```

This produces `lib/node/` and `lib/browser/` used by all other projects via `"file:../protocol-v2/sdk"` dependency.

---

## Step 3: Build Docker Images

### 3a. DLOB Server Image

The DLOB server has an existing `Dockerfile` (`~/dlob-server/Dockerfile`). It runs 3 different processes from the same image.

```bash
cd ~/dlob-server
docker build -t custom-dlob:latest .
```

The single image serves all 3 DLOB processes via different CMD overrides:
- HTTP API: `node lib/index.js`
- Publisher: `node lib/publishers/dlobPublisher.js`
- WS Manager: `node lib/wsConnectionManager.js`

### 3b. Keeper Bots Image

Uses `DockerfileLinked` (`~/keeper-bots-v2/DockerfileLinked`) which includes local SDK linking.

```bash
# Build from HOME directory so both paths are in build context
cd ~
docker build -t custom-keeper:latest \
  -f keeper-bots-v2/DockerfileLinked .
```

CMD: `node ./lib/index.js` — pass config via env vars or mount config file.

### 3c. Perp Bots Image (Oracle Updater + Market Maker)

Uses `~/Perp_bots/Dockerfile` — multi-stage build that compiles TypeScript to `dist/`, copies the SDK into the build context.

```bash
cd ~
docker build -t custom-perp-bots:latest -f Perp_bots/Dockerfile .
```

Uses `ENTRYPOINT ["node", "dist/index.js"]` so CLI args (`--bot`, `--market`) pass through via K8s `args`.

### 3d. Frontend Image

Uses `~/drift-frontend/Dockerfile` — multi-stage build that builds SDK with yarn v1, then installs frontend with Yarn Berry (corepack), runs `next build`.

**Important**: `NEXT_PUBLIC_*` env vars are baked at **build time** in Next.js. Pass them as build args:

```bash
cd ~
docker build -t custom-frontend:latest \
  -f drift-frontend/Dockerfile \
  --build-arg NEXT_PUBLIC_DLOB_HTTP_URL=https://dex.yourdomain.com/dlob \
  --build-arg NEXT_PUBLIC_DLOB_WS_URL=wss://dex.yourdomain.com/ws \
  --build-arg NEXT_PUBLIC_SOLANA_DEVNET_RPC_ENDPOINT=https://your-rpc.com \
  .
```

### 3e. Push Images to Registry

```bash
REGISTRY=registry.local:5000  # or your registry

for img in custom-dlob custom-keeper custom-perp-bots custom-frontend; do
  docker tag $img:latest $REGISTRY/$img:latest
  docker push $REGISTRY/$img:latest
done
```

---

## Step 4: Create K8s Namespace and Secrets

```bash
# Create namespace
kubectl apply -f k8s/perp-dex/00-namespace.yaml

# Shared RPC config
kubectl apply -f k8s/perp-dex/01-configmaps.yaml

# Keeper bots YAML config
kubectl create configmap keeper-config \
  --namespace perp-dex \
  --from-file=config.yaml=~/keeper-bots-v2/custom-dex.config.yaml

# Admin keypair file (for oracle-updater + market-maker)
kubectl create secret generic admin-keypair \
  --namespace perp-dex \
  --from-file=admin-keypair.json=~/protocol-v2/keys/admin-keypair.json

# Keeper bot private key (byte array)
kubectl create secret generic keeper-keys \
  --namespace perp-dex \
  --from-literal=KEEPER_PRIVATE_KEY='[115,189,164,90,230,17,...]'
```

---

## Step 5: Deploy (Ordered)

Deploy components in dependency order using the deploy script:

```bash
cd ~/k8s/perp-dex
./deploy.sh deploy
```

Or manually in order:

```bash
# 1. Redis
kubectl apply -f k8s/perp-dex/02-redis.yaml
kubectl -n perp-dex wait --for=condition=Ready pod -l app=redis --timeout=60s

# 2. DLOB Publisher (writes orderbook to Redis — must be first)
kubectl apply -f k8s/perp-dex/03-dlob-publisher.yaml
kubectl -n perp-dex wait --for=condition=Ready pod -l app=dlob-publisher --timeout=120s

# 3. DLOB API + WS Manager (reads from Redis)
kubectl apply -f k8s/perp-dex/04-dlob-api.yaml
kubectl apply -f k8s/perp-dex/05-dlob-ws.yaml

# 4. Oracle Updater (pushes prices on-chain for TEAM-PERP)
kubectl apply -f k8s/perp-dex/07-oracle-updater.yaml

# 5. Market Maker (places orders on TEAM-PERP)
kubectl apply -f k8s/perp-dex/08-market-maker.yaml

# 6. Keeper Bots (fills, liquidates, settles)
kubectl apply -f k8s/perp-dex/06-keeper-bots.yaml

# 7. Frontend + Ingress
kubectl apply -f k8s/perp-dex/09-frontend.yaml
kubectl apply -f k8s/perp-dex/10-ingress.yaml
```

---

## Step 6: Verification

```bash
# All pods running
kubectl -n perp-dex get pods

# DLOB health
kubectl -n perp-dex exec deploy/dlob-api -- wget -qO- http://localhost:6969/health

# TEAM-PERP orderbook populated
kubectl -n perp-dex exec deploy/dlob-api -- \
  wget -qO- "http://localhost:6969/l2?marketIndex=3&marketType=perp&depth=5"

# Keeper health
kubectl -n perp-dex exec deploy/keeper-bots -- wget -qO- http://localhost:8888/health

# Oracle updater logs (should show price updates every 15s)
kubectl -n perp-dex logs deploy/oracle-updater --tail=20

# Market maker logs (should show level placements every 10s)
kubectl -n perp-dex logs deploy/market-maker --tail=20

# Frontend accessible
kubectl -n perp-dex exec deploy/frontend -- wget -qO- http://localhost:3000
```

---

## Deploy Script Usage

The `deploy.sh` script orchestrates the full workflow:

```bash
cd ~/k8s/perp-dex

./deploy.sh build     # Build all Docker images
./deploy.sh secrets   # Create K8s namespace, secrets, configmaps
./deploy.sh deploy    # Deploy all components in order
./deploy.sh all       # Build + secrets + deploy
./deploy.sh status    # Show pod/service/ingress status
./deploy.sh teardown  # Delete the entire namespace
```

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `REGISTRY` | Container registry (e.g. `registry.local:5000`) |
| `KEEPER_PRIVATE_KEY` | Keeper bot private key byte array |
| `NEXT_PUBLIC_DLOB_HTTP_URL` | External DLOB HTTP URL (baked into frontend at build) |
| `NEXT_PUBLIC_DLOB_WS_URL` | External DLOB WS URL (baked into frontend at build) |
| `NEXT_PUBLIC_SOLANA_DEVNET_RPC_ENDPOINT` | RPC endpoint for frontend |

---

## Ingress Configuration

The ingress routes traffic by path:
- `/` → Frontend (port 3000)
- `/dlob` → DLOB HTTP API (port 6969)
- `/ws` → DLOB WebSocket Manager (port 6970)

Edit `10-ingress.yaml` to set your domain (replace `dex.yourdomain.com`). For TLS, add cert-manager + Let's Encrypt or your own certs.

---

## File Layout

```
~/k8s/perp-dex/
├── deploy.sh                  # Orchestration script
├── DEPLOYMENT.md              # This file
├── 00-namespace.yaml          # perp-dex namespace
├── 01-configmaps.yaml         # RPC endpoint config
├── 02-redis.yaml              # Redis Deployment + Service
├── 03-dlob-publisher.yaml     # DLOB Publisher
├── 04-dlob-api.yaml           # DLOB HTTP API + Service
├── 05-dlob-ws.yaml            # DLOB WS Manager + Service
├── 06-keeper-bots.yaml        # Keeper bots (5 bots)
├── 07-oracle-updater.yaml     # TEAM-PERP oracle updater
├── 08-market-maker.yaml       # TEAM-PERP market maker
├── 09-frontend.yaml           # Next.js frontend + Service
└── 10-ingress.yaml            # Nginx ingress routing

~/Perp_bots/Dockerfile         # Oracle updater + market maker image
~/drift-frontend/Dockerfile    # Frontend image
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| DLOB returns empty orderbook | Publisher not tracking market | Verify `PERP_MARKETS_TO_LOAD=0,1,2,3` |
| "Oracle is stale" for SOL/BTC/ETH | Pyth push feeds not updated on devnet | Expected — TEAM-PERP (Prelaunch oracle) unaffected |
| Keeper health check fails | Slow RPC subscription | Increase `initialDelaySeconds`, check RPC |
| Market maker "PlacePostOnlyLimitFailure" | First batch crosses spread | Transient — recovers on next cycle |
| "unable to verify the first certificate" | TLS issue with RPC | Set `NODE_TLS_REJECT_UNAUTHORIZED=0` (dev only) |
| SDK mismatch errors | Stale SDK in Docker image | Rebuild image with fresh SDK |
| Redis connection refused | Redis pod not ready | `kubectl -n perp-dex get pods -l app=redis` |

---

## Resource Totals

| Resource | CPU Req | CPU Lim | Mem Req | Mem Lim |
|----------|---------|---------|---------|---------|
| Redis | 100m | 500m | 256Mi | 512Mi |
| DLOB Publisher | 250m | 1000m | 512Mi | 1Gi |
| DLOB API | 250m | 1000m | 512Mi | 1Gi |
| DLOB WS | 100m | 500m | 256Mi | 512Mi |
| Keeper Bots | 500m | 2000m | 1Gi | 4Gi |
| Oracle Updater | 100m | 500m | 256Mi | 512Mi |
| Market Maker | 100m | 500m | 256Mi | 512Mi |
| Frontend | 250m | 1000m | 512Mi | 1Gi |
| **Total** | **1650m** | **7000m** | **3.5Gi** | **9.5Gi** |

Minimum viable: **4 CPU / 16 GB RAM** single node.
