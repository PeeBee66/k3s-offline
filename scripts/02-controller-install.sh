#!/bin/bash
set -euo pipefail

###############################################################################
# 02-controller-install.sh
# Installs k3s server (controller) on 192.168.66.198 using offline artefacts.
# Artefacts served from http://192.168.66.198:8080
###############################################################################

K3S_VERSION="${K3S_VERSION:-1.33}"
FILESERVER="http://192.168.66.198:8080"
REGISTRY="192.168.66.198:5000"
NODE_IP="192.168.66.198"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INSTALL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Must run as root
[[ $(id -u) -eq 0 ]] || err "Must run as root (use sudo)"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

###############################################################################
# Step 1: Download artefacts from nginx file server
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
# Step 2: Verify checksum of k3s binary
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
# Step 3: Install k3s-selinux RPM (if SELinux enabled)
###############################################################################
log "=== Step 3: Installing k3s-selinux ==="
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    log "SELinux is active, installing k3s-selinux RPM..."
    if ! rpm -q k3s-selinux &>/dev/null; then
        # Install dependencies
        dnf install -y container-selinux selinux-policy-base policycoreutils 2>/dev/null || true
        curl -fSL -o "$WORK_DIR/k3s-selinux.rpm" "${FILESERVER}/rpm/k3s-selinux-1.6-1.el9.noarch.rpm"
        rpm -ivh --nodeps "$WORK_DIR/k3s-selinux.rpm" || warn "k3s-selinux install had warnings"
    else
        log "k3s-selinux already installed"
    fi
else
    log "SELinux disabled or not present, skipping"
fi

###############################################################################
# Step 4: Place k3s binary
###############################################################################
log "=== Step 4: Installing k3s binary ==="
install -m 755 "$WORK_DIR/k3s" /usr/local/bin/k3s
log "k3s binary installed at /usr/local/bin/k3s"

###############################################################################
# Step 5: Place airgap images
###############################################################################
log "=== Step 5: Staging airgap images ==="
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" /var/lib/rancher/k3s/agent/images/
log "Airgap images staged"

###############################################################################
# Step 6: Configure private registry mirror
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
log "Registry mirror configured at /etc/rancher/k3s/registries.yaml"

###############################################################################
# Step 6b: Open firewall ports
###############################################################################
log "=== Step 6b: Configuring firewall ==="
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=6443/tcp   # k3s API
    firewall-cmd --permanent --add-port=8472/udp   # Flannel VXLAN
    firewall-cmd --permanent --add-port=10250/tcp  # kubelet metrics
    firewall-cmd --permanent --add-port=51820/udp  # WireGuard
    firewall-cmd --permanent --add-port=51821/udp  # WireGuard v6
    firewall-cmd --permanent --add-port=5000/tcp   # Registry
    firewall-cmd --permanent --add-port=8080/tcp   # Nginx
    firewall-cmd --permanent --add-port=8888/tcp   # Gitea
    firewall-cmd --permanent --add-port=9090/tcp   # Portainer
    firewall-cmd --permanent --add-port=9999/tcp   # Dozzle
    firewall-cmd --permanent --add-port=2222/tcp   # Gitea SSH
    firewall-cmd --reload
    log "Firewall configured"
else
    log "No firewalld detected, skipping"
fi

###############################################################################
# Step 7: Run k3s install script
###############################################################################
log "=== Step 7: Running k3s install (server mode) ==="
chmod +x "$WORK_DIR/install.sh"

INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_SKIP_SELINUX_RPM=true \
INSTALL_K3S_EXEC="server \
  --node-ip=${NODE_IP} \
  --disable=cloud-controller-manager \
  --write-kubeconfig-mode=644 \
  --tls-san=${NODE_IP}" \
"$WORK_DIR/install.sh"

###############################################################################
# Step 8: Wait for k3s to be ready
###############################################################################
log "=== Step 8: Waiting for k3s to be ready ==="
TIMEOUT=120
ELAPSED=0
while ! k3s kubectl get nodes &>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        err "k3s did not become ready within ${TIMEOUT}s"
    fi
    log "Waiting for k3s... (${ELAPSED}s)"
done

###############################################################################
# Step 9: Output results
###############################################################################
log "=== Step 9: Installation complete ==="
echo ""
log "Node status:"
k3s kubectl get nodes -o wide
echo ""
log "Node token (save this for worker join):"
cat /var/lib/rancher/k3s/server/node-token
echo ""
log "Kubeconfig: /etc/rancher/k3s/k3s.yaml"
log "To use kubectl: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo ""
log "Next step: Run 03-worker-install.sh on the worker node with the token above"
