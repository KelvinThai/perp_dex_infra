#!/usr/bin/env bash
set -euo pipefail

# Custom Perp DEX — Kubernetes Deployment Script
# Usage: ./deploy.sh [build|secrets|deploy|all|status|teardown]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
NAMESPACE="perp-dex"
REGISTRY="${REGISTRY:-}"  # Set to e.g. "registry.local:5000" or "docker.io/youruser"

# If registry is set, prefix images; otherwise use local images (for k3s/minikube)
img() {
  if [ -n "$REGISTRY" ]; then
    echo "$REGISTRY/$1"
  else
    echo "$1"
  fi
}

build_images() {
  echo "=== Building Docker images ==="

  echo "[1/4] Building SDK..."
  cd "$HOME_DIR/protocol-v2/sdk"
  yarn install --ignore-engines && yarn build

  echo "[2/4] Building custom-dlob..."
  cd "$HOME_DIR/dlob-server"
  docker build -t custom-dlob:latest .

  echo "[3/4] Building custom-keeper..."
  cd "$HOME_DIR"
  docker build -t custom-keeper:latest -f keeper-bots-v2/DockerfileLinked .

  echo "[4/4] Building custom-perp-bots..."
  cd "$HOME_DIR"
  docker build -t custom-perp-bots:latest -f Perp_bots/Dockerfile .

  echo "[5/5] Building custom-frontend..."
  echo "  NOTE: Set NEXT_PUBLIC_DLOB_HTTP_URL and NEXT_PUBLIC_DLOB_WS_URL build args"
  echo "  for external access (browser-side calls). Defaults to localhost."
  cd "$HOME_DIR"
  docker build -t custom-frontend:latest \
    -f drift-frontend/Dockerfile \
    --build-arg NEXT_PUBLIC_DLOB_HTTP_URL="${NEXT_PUBLIC_DLOB_HTTP_URL:-http://localhost:6969}" \
    --build-arg NEXT_PUBLIC_DLOB_WS_URL="${NEXT_PUBLIC_DLOB_WS_URL:-ws://localhost:6970/ws}" \
    --build-arg NEXT_PUBLIC_SOLANA_DEVNET_RPC_ENDPOINT="${NEXT_PUBLIC_SOLANA_DEVNET_RPC_ENDPOINT:-https://api.devnet.solana.com}" \
    .

  if [ -n "$REGISTRY" ]; then
    echo "=== Pushing images to $REGISTRY ==="
    for img_name in custom-dlob custom-keeper custom-perp-bots custom-frontend; do
      docker tag "$img_name:latest" "$REGISTRY/$img_name:latest"
      docker push "$REGISTRY/$img_name:latest"
    done
  fi

  echo "=== All images built ==="
}

create_secrets() {
  echo "=== Creating namespace, secrets, and configmaps ==="

  kubectl apply -f "$SCRIPT_DIR/00-namespace.yaml"

  # ConfigMaps
  kubectl apply -f "$SCRIPT_DIR/01-configmaps.yaml"

  # Keeper config from YAML file
  kubectl create configmap keeper-config \
    --namespace "$NAMESPACE" \
    --from-file=config.yaml="$HOME_DIR/keeper-bots-v2/custom-dex.config.yaml" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Admin keypair (for oracle-updater + market-maker)
  kubectl create secret generic admin-keypair \
    --namespace "$NAMESPACE" \
    --from-file=admin-keypair.json="$HOME_DIR/protocol-v2/keys/admin-keypair.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Keeper private key
  if [ -z "${KEEPER_PRIVATE_KEY:-}" ]; then
    echo ""
    echo "WARNING: KEEPER_PRIVATE_KEY env var not set."
    echo "Set it and re-run, or create the secret manually:"
    echo "  kubectl create secret generic keeper-keys \\"
    echo "    --namespace $NAMESPACE \\"
    echo "    --from-literal=KEEPER_PRIVATE_KEY='[byte,array,here]'"
    echo ""
  else
    kubectl create secret generic keeper-keys \
      --namespace "$NAMESPACE" \
      --from-literal=KEEPER_PRIVATE_KEY="$KEEPER_PRIVATE_KEY" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  echo "=== Secrets and configmaps created ==="
}

deploy() {
  echo "=== Deploying to Kubernetes ==="

  # 1. Redis
  echo "[1/7] Deploying Redis..."
  kubectl apply -f "$SCRIPT_DIR/02-redis.yaml"
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l app=redis --timeout=60s

  # 2. DLOB Publisher (must populate Redis before API/WS start)
  echo "[2/7] Deploying DLOB Publisher..."
  kubectl apply -f "$SCRIPT_DIR/03-dlob-publisher.yaml"
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l app=dlob-publisher --timeout=120s

  # 3. DLOB API + WS Manager
  echo "[3/7] Deploying DLOB API + WS Manager..."
  kubectl apply -f "$SCRIPT_DIR/04-dlob-api.yaml"
  kubectl apply -f "$SCRIPT_DIR/05-dlob-ws.yaml"

  # 4. Oracle Updater
  echo "[4/7] Deploying Oracle Updater..."
  kubectl apply -f "$SCRIPT_DIR/07-oracle-updater.yaml"

  # 5. Market Maker
  echo "[5/7] Deploying Market Maker..."
  kubectl apply -f "$SCRIPT_DIR/08-market-maker.yaml"

  # 6. Keeper Bots
  echo "[6/7] Deploying Keeper Bots..."
  kubectl apply -f "$SCRIPT_DIR/06-keeper-bots.yaml"

  # 7. Frontend + Ingress
  echo "[7/7] Deploying Frontend + Ingress..."
  kubectl apply -f "$SCRIPT_DIR/09-frontend.yaml"
  kubectl apply -f "$SCRIPT_DIR/10-ingress.yaml"

  echo ""
  echo "=== Deployment complete ==="
  echo "Run './deploy.sh status' to check pod health."
}

status() {
  echo "=== Pod Status ==="
  kubectl -n "$NAMESPACE" get pods -o wide
  echo ""
  echo "=== Services ==="
  kubectl -n "$NAMESPACE" get svc
  echo ""
  echo "=== Ingress ==="
  kubectl -n "$NAMESPACE" get ingress
}

teardown() {
  echo "=== Tearing down perp-dex namespace ==="
  read -p "This will delete ALL resources in the '$NAMESPACE' namespace. Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    kubectl delete namespace "$NAMESPACE"
    echo "Namespace $NAMESPACE deleted."
  else
    echo "Aborted."
  fi
}

# --- Main ---
case "${1:-help}" in
  build)    build_images ;;
  secrets)  create_secrets ;;
  deploy)   deploy ;;
  all)
    build_images
    create_secrets
    deploy
    ;;
  status)   status ;;
  teardown) teardown ;;
  *)
    echo "Usage: $0 {build|secrets|deploy|all|status|teardown}"
    echo ""
    echo "  build     - Build all Docker images"
    echo "  secrets   - Create K8s namespace, secrets, and configmaps"
    echo "  deploy    - Deploy all components (in correct order)"
    echo "  all       - Build + secrets + deploy"
    echo "  status    - Show pod/service/ingress status"
    echo "  teardown  - Delete the entire namespace"
    echo ""
    echo "Environment variables:"
    echo "  REGISTRY                              - Container registry (e.g. registry.local:5000)"
    echo "  KEEPER_PRIVATE_KEY                     - Keeper bot private key byte array"
    echo "  NEXT_PUBLIC_DLOB_HTTP_URL              - External DLOB HTTP URL (baked into frontend)"
    echo "  NEXT_PUBLIC_DLOB_WS_URL                - External DLOB WS URL (baked into frontend)"
    echo "  NEXT_PUBLIC_SOLANA_DEVNET_RPC_ENDPOINT - RPC endpoint for frontend"
    ;;
esac
