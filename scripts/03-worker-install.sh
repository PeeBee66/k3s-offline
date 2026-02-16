#!/bin/bash
set -euo pipefail

###############################################################################
# 03-worker-install.sh
# Installs k3s agent (worker) and joins it to the cluster.
#
# Variables:
#   DATA_SERVER  — IP of the file server + registry host (default: 192.168.66.198)
#   K3S_VERSION  — Version folder: 1.33 or 1.35 (default: 1.33)
#   K3S_TOKEN    — Node token from primary controller (required)
#   CONTROLLER_IP — IP of a controller node to join (default: DATA_SERVER)
#
# The node IP is auto-detected from the default route interface.
#
# Usage:
#   sudo K3S_TOKEN=<token> DATA_SERVER=192.168.66.198 ./03-worker-install.sh
#   sudo K3S_TOKEN=<token> CONTROLLER_IP=10.0.0.1 DATA_SERVER=10.0.0.1 ./03-worker-install.sh
###############################################################################

K3S_VERSION="${K3S_VERSION:-1.33}"
DATA_SERVER="${DATA_SERVER:-192.168.66.198}"
CONTROLLER_IP="${CONTROLLER_IP:-${DATA_SERVER}}"
K3S_TOKEN="${K3S_TOKEN:-${1:-}}"

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
[[ -n "$K3S_TOKEN" ]] || err "K3S_TOKEN is required. Pass as env var or first argument."

# Auto-detect node IP
NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || hostname -I | awk '{print $1}')
[[ -n "$NODE_IP" ]] || err "Could not detect node IP"

log "========================================="
log "  k3s Worker Install"
log "========================================="
log "  Node IP:       ${NODE_IP}"
log "  Controller IP: ${CONTROLLER_IP}"
log "  Data Server:   ${DATA_SERVER}"
log "  File Server:   ${FILESERVER}"
log "  Registry:      ${REGISTRY}"
log "  k3s Version:   ${K3S_VERSION}"
log "========================================="
echo ""

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

###############################################################################
# Step 1: Download artefacts
###############################################################################
log "=== Step 1: Downloading artefacts ==="
curl -fSL -o "$WORK_DIR/k3s" "${FILESERVER}/k3s/${K3S_VERSION}/k3s"
curl -fSL -o "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" \
    "${FILESERVER}/k3s/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"
curl -fSL -o "$WORK_DIR/install.sh" "${FILESERVER}/k3s/${K3S_VERSION}/install.sh"
curl -fSL -o "$WORK_DIR/sha256sum-amd64.txt" \
    "${FILESERVER}/k3s/${K3S_VERSION}/sha256sum-amd64.txt"

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
    err "Checksum MISMATCH!"
fi

###############################################################################
# Step 3: SELinux
###############################################################################
log "=== Step 3: SELinux ==="
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    if ! rpm -q k3s-selinux &>/dev/null; then
        dnf install -y container-selinux selinux-policy-base policycoreutils 2>/dev/null || true
        curl -fSL -o "$WORK_DIR/k3s-selinux.rpm" "${FILESERVER}/rpm/k3s-selinux-1.6-1.el9.noarch.rpm"
        rpm -ivh --nodeps "$WORK_DIR/k3s-selinux.rpm" || warn "k3s-selinux warnings"
    else
        log "k3s-selinux already installed"
    fi
else
    log "SELinux disabled, skipping"
fi

###############################################################################
# Step 4: Place binary + images
###############################################################################
log "=== Step 4: Installing binary + images ==="
install -m 755 "$WORK_DIR/k3s" /usr/local/bin/k3s
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" /var/lib/rancher/k3s/agent/images/

###############################################################################
# Step 5: Registry mirror
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
    for port in 8472/udp 10250/tcp 51820/udp 51821/udp; do
        firewall-cmd --permanent --add-port="$port" 2>/dev/null || true
    done
    firewall-cmd --reload
    log "Firewall ports opened"
else
    log "No firewalld, skipping"
fi

###############################################################################
# Step 7: Install k3s agent
###############################################################################
log "=== Step 7: Installing k3s agent ==="
chmod +x "$WORK_DIR/install.sh"

INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_SKIP_SELINUX_RPM=true \
K3S_URL="https://${CONTROLLER_IP}:6443" \
K3S_TOKEN="${K3S_TOKEN}" \
INSTALL_K3S_EXEC="agent --node-ip=${NODE_IP}" \
"$WORK_DIR/install.sh"

###############################################################################
# Step 8: Wait for agent
###############################################################################
log "=== Step 8: Waiting for agent service ==="
TIMEOUT=60
ELAPSED=0
while ! systemctl is-active --quiet k3s-agent; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    [[ $ELAPSED -ge $TIMEOUT ]] && err "k3s-agent did not start within ${TIMEOUT}s"
    log "Waiting... (${ELAPSED}s)"
done

log "========================================="
log "  Worker Install Complete"
log "========================================="
echo ""
log "Node IP: ${NODE_IP}"
log "Joined:  https://${CONTROLLER_IP}:6443"
log "Verify from controller: k3s kubectl get nodes"
