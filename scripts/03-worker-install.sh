#!/bin/bash
set -euo pipefail

###############################################################################
# 03-worker-install.sh
# Installs k3s agent (worker) and joins it to the controller cluster.
# Run on 192.168.66.199
#
# Usage: sudo ./03-worker-install.sh <NODE_TOKEN>
#   or:  sudo K3S_TOKEN=<token> ./03-worker-install.sh
###############################################################################

K3S_VERSION="${K3S_VERSION:-1.33}"
CONTROLLER_IP="${CONTROLLER_IP:-192.168.66.198}"
FILESERVER="${FILESERVER:-http://192.168.66.198:8080}"
REGISTRY="${REGISTRY:-192.168.66.198:5000}"

# Token from arg or env
if [[ -n "${1:-}" ]]; then
    K3S_TOKEN="$1"
elif [[ -z "${K3S_TOKEN:-}" ]]; then
    echo "Usage: $0 <NODE_TOKEN>"
    echo "  or:  K3S_TOKEN=<token> $0"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INSTALL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || err "Must run as root (use sudo)"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

###############################################################################
# Step 1: Download artefacts
###############################################################################
log "=== Step 1: Downloading artefacts (k3s ${K3S_VERSION}) ==="

log "Downloading k3s binary..."
curl -fSL -o "$WORK_DIR/k3s" "${FILESERVER}/k3s/${K3S_VERSION}/k3s"

log "Downloading airgap images..."
curl -fSL -o "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" \
    "${FILESERVER}/k3s/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"

log "Downloading install script..."
curl -fSL -o "$WORK_DIR/install.sh" "${FILESERVER}/k3s/${K3S_VERSION}/install.sh"

log "Downloading checksums..."
curl -fSL -o "$WORK_DIR/sha256sum-amd64.txt" \
    "${FILESERVER}/k3s/${K3S_VERSION}/sha256sum-amd64.txt"

###############################################################################
# Step 2: Verify checksum
###############################################################################
log "=== Step 2: Verifying k3s binary checksum ==="
cd "$WORK_DIR"
expected=$(grep "  k3s$" sha256sum-amd64.txt | awk '{print $1}')
actual=$(sha256sum k3s | awk '{print $1}')
if [[ "$expected" == "$actual" ]]; then
    log "Checksum verified: PASS"
else
    err "Checksum MISMATCH! Expected: $expected Got: $actual"
fi

###############################################################################
# Step 3: Install k3s-selinux
###############################################################################
log "=== Step 3: Installing k3s-selinux ==="
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
# Step 4: Place binary
###############################################################################
log "=== Step 4: Installing k3s binary ==="
install -m 755 "$WORK_DIR/k3s" /usr/local/bin/k3s

###############################################################################
# Step 5: Place airgap images
###############################################################################
log "=== Step 5: Staging airgap images ==="
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" /var/lib/rancher/k3s/agent/images/

###############################################################################
# Step 6: Configure registry mirror
###############################################################################
log "=== Step 6: Configuring registry mirror ==="
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
# Step 6b: Open firewall ports
###############################################################################
log "=== Step 6b: Configuring firewall ==="
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=8472/udp   # Flannel VXLAN
    firewall-cmd --permanent --add-port=10250/tcp  # kubelet metrics
    firewall-cmd --permanent --add-port=51820/udp  # WireGuard
    firewall-cmd --permanent --add-port=51821/udp  # WireGuard v6
    firewall-cmd --reload
    log "Firewall configured"
else
    log "No firewalld detected, skipping"
fi

###############################################################################
# Step 7: Run k3s install (agent mode)
###############################################################################
log "=== Step 7: Running k3s install (agent mode) ==="
chmod +x "$WORK_DIR/install.sh"

INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_SKIP_SELINUX_RPM=true \
K3S_URL="https://${CONTROLLER_IP}:6443" \
K3S_TOKEN="${K3S_TOKEN}" \
"$WORK_DIR/install.sh"

###############################################################################
# Step 8: Wait for agent to register
###############################################################################
log "=== Step 8: Waiting for agent service ==="
TIMEOUT=60
ELAPSED=0
while ! systemctl is-active --quiet k3s-agent; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        err "k3s-agent did not start within ${TIMEOUT}s"
    fi
    log "Waiting... (${ELAPSED}s)"
done

log "=== Installation complete ==="
echo ""
log "k3s-agent is running"
log "Verify from controller: k3s kubectl get nodes"
log "This node should appear as Ready within ~30s"
