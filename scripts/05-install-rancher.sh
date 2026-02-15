#!/bin/bash
set -euo pipefail

###############################################################################
# 05-install-rancher.sh
# Offline install of cert-manager + Rancher on k3s cluster.
# Run on the controller node (192.168.66.198).
###############################################################################

FILESERVER="http://192.168.66.198:8080"
REGISTRY="192.168.66.198:5000"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.local}"
RANCHER_VERSION="2.13.2"
CERTMGR_VERSION="v1.11.0"
HELM_VERSION="v3.20.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[RANCHER]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || err "Must run as root"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Verify cluster is up
k3s kubectl get nodes &>/dev/null || err "k3s cluster not reachable. Install k3s first."

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

###############################################################################
# Step 1: Install Helm binary
###############################################################################
log "=== Step 1: Installing Helm ==="
if ! command -v helm &>/dev/null; then
    curl -fSL -o "$WORK_DIR/helm.tar.gz" \
        "${FILESERVER}/helm/helm-${HELM_VERSION}-linux-amd64.tar.gz"
    tar -xzf "$WORK_DIR/helm.tar.gz" -C "$WORK_DIR"
    install -m 755 "$WORK_DIR/linux-amd64/helm" /usr/local/bin/helm
    log "Helm installed: $(helm version --short)"
else
    log "Helm already installed: $(helm version --short)"
fi

###############################################################################
# Step 2: Download Helm charts and CRDs
###############################################################################
log "=== Step 2: Downloading charts ==="
curl -fSL -o "$WORK_DIR/cert-manager.tgz" \
    "${FILESERVER}/helm/cert-manager-${CERTMGR_VERSION}.tgz"

curl -fSL -o "$WORK_DIR/rancher.tgz" \
    "${FILESERVER}/helm/rancher-${RANCHER_VERSION}.tgz"

curl -fSL -o "$WORK_DIR/cert-manager-crd.yaml" \
    "${FILESERVER}/helm/cert-manager-crd.yaml"

###############################################################################
# Step 3: Install cert-manager CRDs
###############################################################################
log "=== Step 3: Applying cert-manager CRDs ==="
k3s kubectl apply -f "$WORK_DIR/cert-manager-crd.yaml"
log "CRDs applied"

###############################################################################
# Step 4: Install cert-manager
###############################################################################
log "=== Step 4: Installing cert-manager ==="
k3s kubectl create namespace cert-manager 2>/dev/null || log "Namespace cert-manager exists"

helm upgrade --install cert-manager "$WORK_DIR/cert-manager.tgz" \
    --namespace cert-manager \
    --set installCRDs=false \
    --set image.repository="${REGISTRY}/quay.io/jetstack/cert-manager-controller" \
    --set image.tag="${CERTMGR_VERSION}" \
    --set webhook.image.repository="${REGISTRY}/quay.io/jetstack/cert-manager-webhook" \
    --set webhook.image.tag="${CERTMGR_VERSION}" \
    --set cainjector.image.repository="${REGISTRY}/quay.io/jetstack/cert-manager-cainjector" \
    --set cainjector.image.tag="${CERTMGR_VERSION}" \
    --set startupapicheck.image.repository="${REGISTRY}/quay.io/jetstack/cert-manager-ctl" \
    --set startupapicheck.image.tag="${CERTMGR_VERSION}" \
    --wait --timeout 5m

log "cert-manager installed"

# Wait for cert-manager webhook to be ready
log "Waiting for cert-manager webhook..."
k3s kubectl -n cert-manager rollout status deployment cert-manager-webhook --timeout=120s

###############################################################################
# Step 5: Install Rancher
###############################################################################
log "=== Step 5: Installing Rancher ==="
k3s kubectl create namespace cattle-system 2>/dev/null || log "Namespace cattle-system exists"

helm upgrade --install rancher "$WORK_DIR/rancher.tgz" \
    --namespace cattle-system \
    --set hostname="${RANCHER_HOSTNAME}" \
    --set certmanager.version="${CERTMGR_VERSION}" \
    --set rancherImage="${REGISTRY}/rancher/rancher" \
    --set rancherImageTag="${RANCHER_VERSION}" \
    --set systemDefaultRegistry="${REGISTRY}" \
    --set useBundledSystemChart=true \
    --set replicas=1 \
    --wait --timeout 10m

log "Rancher installed"

###############################################################################
# Step 6: Wait and verify
###############################################################################
log "=== Step 6: Verifying ==="

log "Waiting for Rancher deployment..."
k3s kubectl -n cattle-system rollout status deployment rancher --timeout=300s

echo ""
log "cert-manager pods:"
k3s kubectl get pods -n cert-manager | sed 's/^/  /'
echo ""
log "Rancher pods:"
k3s kubectl get pods -n cattle-system | sed 's/^/  /'
echo ""

# Get bootstrap password
BOOTSTRAP_PWD=$(k3s kubectl get secret --namespace cattle-system bootstrap-secret \
    -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null || echo "not-yet-available")

log "========================================="
log "  Rancher Installation Complete"
log "========================================="
echo ""
log "URL:                https://${RANCHER_HOSTNAME}"
log "Bootstrap password: ${BOOTSTRAP_PWD}"
echo ""
log "If using self-signed certs, add to /etc/hosts:"
log "  ${REGISTRY%:*}  ${RANCHER_HOSTNAME}"
echo ""
log "Access via: https://192.168.66.198 (accept self-signed cert warning)"
