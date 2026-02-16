#!/bin/bash
set -euo pipefail

###############################################################################
# 02-controller-install.sh
# Installs k3s server (controller) node.
#
# Supports:
#   MODE=pri  — Primary controller (initialises new cluster with --cluster-init)
#   MODE=sec  — Secondary controller (joins existing cluster as control-plane)
#
# Variables:
#   DATA_SERVER  — IP of the file server + registry host (default: 192.168.66.198)
#   K3S_VERSION  — Version folder to use: 1.33 or 1.35 (default: 1.33)
#   MODE         — pri or sec (default: pri)
#   K3S_TOKEN    — Required for sec mode (from primary controller)
#   PRI_IP       — Required for sec mode (primary controller IP)
#
# The node IP is auto-detected from the default route interface.
# The registry is at DATA_SERVER:5000, file server at DATA_SERVER:8080.
#
# Usage:
#   sudo MODE=pri DATA_SERVER=192.168.66.198 ./02-controller-install.sh
#   sudo MODE=sec PRI_IP=192.168.66.198 K3S_TOKEN=<token> ./02-controller-install.sh
###############################################################################

K3S_VERSION="${K3S_VERSION:-1.33}"
DATA_SERVER="${DATA_SERVER:-192.168.66.198}"
MODE="${MODE:-pri}"
PRI_IP="${PRI_IP:-}"
K3S_TOKEN="${K3S_TOKEN:-}"

FILESERVER="http://${DATA_SERVER}:8080"
REGISTRY="${DATA_SERVER}:5000"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INSTALL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || err "Must run as root (use sudo)"

# Validate mode
MODE=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')
case "$MODE" in
    pri|primary) MODE="pri" ;;
    sec|secondary) MODE="sec" ;;
    *) err "Invalid MODE: $MODE (must be pri or sec)" ;;
esac

# Secondary mode requires token and primary IP
if [[ "$MODE" == "sec" ]]; then
    [[ -n "$K3S_TOKEN" ]] || err "MODE=sec requires K3S_TOKEN"
    [[ -n "$PRI_IP" ]] || err "MODE=sec requires PRI_IP (primary controller IP)"
fi

# Auto-detect node IP from default route
NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || hostname -I | awk '{print $1}')
[[ -n "$NODE_IP" ]] || err "Could not detect node IP"

log "========================================="
log "  k3s Controller Install"
log "========================================="
log "  Mode:        ${MODE}"
log "  Node IP:     ${NODE_IP}"
log "  Data Server: ${DATA_SERVER}"
log "  File Server: ${FILESERVER}"
log "  Registry:    ${REGISTRY}"
log "  k3s Version: ${K3S_VERSION}"
[[ "$MODE" == "sec" ]] && log "  Primary IP:  ${PRI_IP}"
log "========================================="
echo ""

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

###############################################################################
# Step 1: Download artefacts from file server
###############################################################################
log "=== Step 1: Downloading artefacts ==="

curl -fSL -o "$WORK_DIR/k3s" "${FILESERVER}/k3s/${K3S_VERSION}/k3s"
curl -fSL -o "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" \
    "${FILESERVER}/k3s/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"
curl -fSL -o "$WORK_DIR/install.sh" "${FILESERVER}/k3s/${K3S_VERSION}/install.sh"
curl -fSL -o "$WORK_DIR/sha256sum-amd64.txt" \
    "${FILESERVER}/k3s/${K3S_VERSION}/sha256sum-amd64.txt"
log "Downloads complete"

###############################################################################
# Step 2: Verify checksum
###############################################################################
log "=== Step 2: Verifying checksum ==="
cd "$WORK_DIR"
expected=$(grep "  k3s$" sha256sum-amd64.txt | awk '{print $1}')
actual=$(sha256sum k3s | awk '{print $1}')
if [[ "$expected" == "$actual" ]]; then
    log "Checksum: PASS"
else
    err "Checksum MISMATCH! Expected: $expected Got: $actual"
fi

###############################################################################
# Step 3: Install k3s-selinux
###############################################################################
log "=== Step 3: SELinux ==="
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    if ! rpm -q k3s-selinux &>/dev/null; then
        dnf install -y container-selinux selinux-policy-base policycoreutils 2>/dev/null || true
        curl -fSL -o "$WORK_DIR/k3s-selinux.rpm" "${FILESERVER}/rpm/k3s-selinux-1.6-1.el9.noarch.rpm"
        rpm -ivh --nodeps "$WORK_DIR/k3s-selinux.rpm" || warn "k3s-selinux install had warnings"
    else
        log "k3s-selinux already installed"
    fi
else
    log "SELinux disabled, skipping"
fi

###############################################################################
# Step 4: Place binary and images
###############################################################################
log "=== Step 4: Installing binary + images ==="
install -m 755 "$WORK_DIR/k3s" /usr/local/bin/k3s
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" /var/lib/rancher/k3s/agent/images/

###############################################################################
# Step 5: Configure registry mirror
###############################################################################
log "=== Step 5: Registry mirror ==="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "http://${REGISTRY}"
  quay.io:
    endpoint:
      - "http://${REGISTRY}"
  ghcr.io:
    endpoint:
      - "http://${REGISTRY}"
configs:
  "${REGISTRY}":
    tls:
      insecure_skip_verify: true
EOF

###############################################################################
# Step 6: Firewall
###############################################################################
log "=== Step 6: Firewall ==="
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    for port in 6443/tcp 8472/udp 10250/tcp 51820/udp 51821/udp 2379/tcp 2380/tcp; do
        firewall-cmd --permanent --add-port="$port" 2>/dev/null || true
    done
    firewall-cmd --reload
    log "Firewall ports opened"
else
    log "No firewalld, skipping"
fi

###############################################################################
# Step 7: Install k3s
###############################################################################
log "=== Step 7: Installing k3s (${MODE} controller) ==="
chmod +x "$WORK_DIR/install.sh"

if [[ "$MODE" == "pri" ]]; then
    # Primary controller — initialise cluster with embedded etcd
    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_EXEC="server \
      --cluster-init \
      --node-ip=${NODE_IP} \
      --disable=cloud-controller-manager \
      --write-kubeconfig-mode=644 \
      --tls-san=${NODE_IP}" \
    "$WORK_DIR/install.sh"
else
    # Secondary controller — join existing cluster
    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_SELINUX_RPM=true \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="server \
      --server=https://${PRI_IP}:6443 \
      --node-ip=${NODE_IP} \
      --disable=cloud-controller-manager \
      --write-kubeconfig-mode=644 \
      --tls-san=${NODE_IP}" \
    "$WORK_DIR/install.sh"
fi

###############################################################################
# Step 8: Wait for ready
###############################################################################
log "=== Step 8: Waiting for node Ready ==="
TIMEOUT=300
ELAPSED=0
while ! k3s kubectl get nodes &>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        err "k3s did not become ready within ${TIMEOUT}s"
    fi
    log "Waiting... (${ELAPSED}s)"
done

# Wait for this specific node
while true; do
    status=$(k3s kubectl get node "$(hostname | tr '[:upper:]' '[:lower:]')" --no-headers 2>/dev/null | awk '{print $2}' || echo "NotReady")
    [[ "$status" == "Ready" ]] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    [[ $ELAPSED -ge $TIMEOUT ]] && err "Node not Ready within ${TIMEOUT}s"
    log "Waiting for Ready... (${ELAPSED}s) — status: $status"
done

###############################################################################
# Step 9: Output
###############################################################################
log "========================================="
log "  Installation Complete (${MODE})"
log "========================================="
echo ""
log "Node status:"
k3s kubectl get nodes -o wide
echo ""

if [[ "$MODE" == "pri" ]]; then
    log "Node token (use for sec controllers and workers):"
    cat /var/lib/rancher/k3s/server/node-token
    echo ""
fi

log "Kubeconfig: /etc/rancher/k3s/k3s.yaml"
log "Node IP:    ${NODE_IP}"
echo ""
