#!/bin/bash
set -euo pipefail

###############################################################################
# 06-upgrade.sh
# Version-driven k3s rolling upgrade.
# Upgrades controller first, then worker.
#
# Usage: sudo ./06-upgrade.sh <version>
#   e.g.: sudo ./06-upgrade.sh 1.35
###############################################################################

TARGET_VERSION="${1:-}"
CONTROLLER_IP="192.168.66.198"
WORKER_IP="192.168.66.199"
WORKER_USER="${WORKER_USER:-pb}"
WORKER_PASS="${WORKER_PASS:-Password20}"
FILESERVER="http://192.168.66.198:8080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[UPGRADE]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

if [[ -z "$TARGET_VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "  e.g.: $0 1.35"
    exit 1
fi

[[ $(id -u) -eq 0 ]] || err "Must run as root"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

###############################################################################
# Pre-flight checks
###############################################################################
log "=== Pre-flight checks ==="

k3s kubectl get nodes &>/dev/null || err "Cluster not reachable"

log "Current node versions:"
k3s kubectl get nodes -o wide | sed 's/^/  /'
echo ""

# Verify artefacts exist
log "Checking artefacts for version ${TARGET_VERSION}..."
curl -sf "${FILESERVER}/k3s/${TARGET_VERSION}/k3s" -o /dev/null \
    || err "k3s binary not found at ${FILESERVER}/k3s/${TARGET_VERSION}/k3s"
curl -sf "${FILESERVER}/k3s/${TARGET_VERSION}/k3s-airgap-images-amd64.tar.zst" -o /dev/null \
    || err "Airgap images not found"
log "Artefacts verified"

# Capture current workloads
log "Capturing workload state..."
k3s kubectl get pods -A --no-headers | wc -l > /tmp/k3s-pre-upgrade-pod-count

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

###############################################################################
# Download artefacts
###############################################################################
log "=== Downloading upgrade artefacts ==="
curl -fSL -o "$WORK_DIR/k3s" "${FILESERVER}/k3s/${TARGET_VERSION}/k3s"
curl -fSL -o "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" \
    "${FILESERVER}/k3s/${TARGET_VERSION}/k3s-airgap-images-amd64.tar.zst"
curl -fSL -o "$WORK_DIR/sha256sum-amd64.txt" \
    "${FILESERVER}/k3s/${TARGET_VERSION}/sha256sum-amd64.txt"

# Verify checksum
cd "$WORK_DIR"
expected=$(grep "  k3s$" sha256sum-amd64.txt | awk '{print $1}')
actual=$(sha256sum k3s | awk '{print $1}')
if [[ "$expected" == "$actual" ]]; then
    log "Binary checksum: PASS"
else
    err "Binary checksum MISMATCH!"
fi

###############################################################################
# Phase 1: Upgrade Controller
###############################################################################
log "========================================="
log "  Phase 1: Upgrading Controller"
log "========================================="

# Replace binary
log "Replacing k3s binary on controller..."
install -m 755 "$WORK_DIR/k3s" /usr/local/bin/k3s

# Replace airgap images
log "Replacing airgap images on controller..."
cp "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" /var/lib/rancher/k3s/agent/images/

# Restart k3s server
log "Restarting k3s service..."
systemctl restart k3s

# Wait for controller to be ready
log "Waiting for controller to be Ready..."
TIMEOUT=180
ELAPSED=0
while true; do
    status=$(k3s kubectl get node "$(hostname)" --no-headers 2>/dev/null | awk '{print $2}' || echo "NotReady")
    if [[ "$status" == "Ready" ]]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        err "Controller did not become Ready within ${TIMEOUT}s"
    fi
    log "Waiting... (${ELAPSED}s) — status: $status"
done

log "Controller upgraded and Ready"
k3s kubectl get nodes | sed 's/^/  /'
echo ""

###############################################################################
# Phase 2: Upgrade Worker
###############################################################################
log "========================================="
log "  Phase 2: Upgrading Worker (${WORKER_IP})"
log "========================================="

# Check if sshpass is available
command -v sshpass &>/dev/null || err "sshpass not installed — needed for worker upgrade"

SSH_CMD="sshpass -p '${WORKER_PASS}' ssh -o StrictHostKeyChecking=no ${WORKER_USER}@${WORKER_IP}"

# Copy artefacts to worker
log "Copying artefacts to worker..."
sshpass -p "${WORKER_PASS}" scp -o StrictHostKeyChecking=no \
    "$WORK_DIR/k3s" "$WORK_DIR/k3s-airgap-images-amd64.tar.zst" \
    "${WORKER_USER}@${WORKER_IP}:/tmp/"

# Run upgrade on worker
log "Running upgrade on worker..."
sshpass -p "${WORKER_PASS}" ssh -o StrictHostKeyChecking=no "${WORKER_USER}@${WORKER_IP}" \
    "echo '${WORKER_PASS}' | sudo -S bash -c '
        install -m 755 /tmp/k3s /usr/local/bin/k3s && \
        cp /tmp/k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/ && \
        systemctl restart k3s-agent && \
        echo UPGRADE_DONE
    '" 2>&1

# Wait for worker to be Ready
log "Waiting for worker to be Ready..."
TIMEOUT=180
ELAPSED=0
while true; do
    ready_count=$(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
    total_count=$(k3s kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "$ready_count" -eq "$total_count" && "$total_count" -ge 2 ]]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        err "Worker did not become Ready within ${TIMEOUT}s"
    fi
    log "Waiting... (${ELAPSED}s) — ${ready_count}/${total_count} Ready"
done

log "Worker upgraded and Ready"

###############################################################################
# Validation
###############################################################################
log "========================================="
log "  Post-Upgrade Validation"
log "========================================="

echo ""
log "Node versions:"
k3s kubectl get nodes -o wide | sed 's/^/  /'
echo ""

# Verify workloads survived
post_count=$(k3s kubectl get pods -A --no-headers 2>/dev/null | wc -l)
pre_count=$(cat /tmp/k3s-pre-upgrade-pod-count 2>/dev/null || echo "?")
log "Pod count: pre=${pre_count} post=${post_count}"

# Check for CrashLoopBackOff or Error pods
bad_pods=$(k3s kubectl get pods -A --no-headers 2>/dev/null | grep -cE "CrashLoop|Error|ImagePull" || true)
if [[ $bad_pods -gt 0 ]]; then
    warn "${bad_pods} pods in error state:"
    k3s kubectl get pods -A --no-headers | grep -E "CrashLoop|Error|ImagePull" | sed 's/^/  /'
else
    log "All pods healthy"
fi

echo ""
log "All pods:"
k3s kubectl get pods -A | sed 's/^/  /'

echo ""
log "========================================="
log "  Upgrade to k3s ${TARGET_VERSION} complete"
log "========================================="
