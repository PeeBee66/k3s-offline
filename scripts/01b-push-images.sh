#!/bin/bash
set -euo pipefail

###############################################################################
# 01b-push-images.sh
# Pulls container images from internet and pushes to local registry.
# TESTING ONLY — not used in production (images loaded differently in prod).
#
# Requires: docker with insecure-registries configured for DATA_SERVER.
###############################################################################

DATA_SERVER="${DATA_SERVER:-192.168.66.198}"
REGISTRY="${DATA_SERVER}:5000"

RANCHER_VERSION="v2.13.2"
CERTMGR_VERSION="v1.11.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[PUSH]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Verify docker is available
command -v docker &>/dev/null || err "docker not found"

# Verify registry is reachable
curl -sf "http://${REGISTRY}/v2/" &>/dev/null || err "Registry not reachable at http://${REGISTRY}/v2/"

push_image() {
    local img="$1"
    local local_tag="${REGISTRY}/${img}"
    log "Pulling $img"
    docker pull "$img" || { warn "Failed to pull: $img"; return 1; }
    docker tag "$img" "$local_tag"
    log "Pushing $local_tag"
    docker push "$local_tag" || { warn "Failed to push: $local_tag"; return 1; }
    log "OK: $img"
}

###############################################################################
log "=== cert-manager images ==="
###############################################################################
for img in \
    "quay.io/jetstack/cert-manager-controller:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-webhook:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-cainjector:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-ctl:${CERTMGR_VERSION}"; do
    push_image "$img"
done

###############################################################################
log "=== Core Rancher images ==="
###############################################################################
for img in \
    "rancher/rancher:${RANCHER_VERSION}" \
    "rancher/rancher-agent:${RANCHER_VERSION}" \
    "rancher/rancher-webhook:v0.9.2" \
    "rancher/shell:v0.6.1" \
    "rancher/fleet:v0.14.2" \
    "rancher/fleet-agent:v0.14.2"; do
    push_image "$img" || true
done

###############################################################################
echo ""
log "========================================="
log "  IMAGE PUSH COMPLETE"
log "========================================="
echo ""
log "Registry catalog:"
curl -s "http://${REGISTRY}/v2/_catalog" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://${REGISTRY}/v2/_catalog"
echo ""
