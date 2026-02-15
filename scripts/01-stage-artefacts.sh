#!/bin/bash
set -euo pipefail

###############################################################################
# 01-stage-artefacts.sh
# Downloads all k3s, Helm, Rancher, and cert-manager artefacts for offline use.
# Run this on an internet-connected machine.
# Everything is staged under /home/pb/fileserver/
###############################################################################

FILESERVER_ROOT="/home/pb/fileserver"
REGISTRY="192.168.66.198:5000"

# Version pinning
K3S_V133="v1.33.8+k3s1"
K3S_V135="v1.35.1+k3s1"
HELM_VERSION="v3.20.0"
RANCHER_VERSION="v2.13.2"
CERTMGR_VERSION="v1.11.0"
K3S_SELINUX_VERSION="v1.6.stable.1"

# URL-encoded versions (+ becomes %2B)
K3S_V133_ENC="v1.33.8%2Bk3s1"
K3S_V135_ENC="v1.35.1%2Bk3s1"

GITHUB_K3S="https://github.com/k3s-io/k3s/releases/download"
GITHUB_SELINUX="https://github.com/k3s-io/k3s-selinux/releases/download"
GITHUB_RANCHER="https://github.com/rancher/rancher/releases/download"
GITHUB_CERTMGR="https://github.com/cert-manager/cert-manager/releases/download"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[STAGE]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

download() {
    local url="$1"
    local dest="$2"
    if [[ -f "$dest" ]]; then
        log "Already exists: $dest"
        return 0
    fi
    log "Downloading: $url"
    curl -fSL --progress-bar -o "$dest" "$url"
}

###############################################################################
# Create directory structure
###############################################################################
log "Creating directory structure..."
mkdir -p "$FILESERVER_ROOT"/{k3s/1.33,k3s/1.35,helm,rpm,images,scripts,repos}

###############################################################################
# k3s v1.33.x artefacts
###############################################################################
log "=== Downloading k3s v1.33 artefacts ==="
download "${GITHUB_K3S}/${K3S_V133_ENC}/k3s" \
         "$FILESERVER_ROOT/k3s/1.33/k3s"

download "${GITHUB_K3S}/${K3S_V133_ENC}/k3s-airgap-images-amd64.tar.zst" \
         "$FILESERVER_ROOT/k3s/1.33/k3s-airgap-images-amd64.tar.zst"

download "${GITHUB_K3S}/${K3S_V133_ENC}/sha256sum-amd64.txt" \
         "$FILESERVER_ROOT/k3s/1.33/sha256sum-amd64.txt"

###############################################################################
# k3s v1.35.x artefacts
###############################################################################
log "=== Downloading k3s v1.35 artefacts ==="
download "${GITHUB_K3S}/${K3S_V135_ENC}/k3s" \
         "$FILESERVER_ROOT/k3s/1.35/k3s"

download "${GITHUB_K3S}/${K3S_V135_ENC}/k3s-airgap-images-amd64.tar.zst" \
         "$FILESERVER_ROOT/k3s/1.35/k3s-airgap-images-amd64.tar.zst"

download "${GITHUB_K3S}/${K3S_V135_ENC}/sha256sum-amd64.txt" \
         "$FILESERVER_ROOT/k3s/1.35/sha256sum-amd64.txt"

###############################################################################
# k3s install script (shared)
###############################################################################
log "=== Downloading k3s install script ==="
download "https://get.k3s.io" "$FILESERVER_ROOT/k3s/1.33/install.sh"
cp "$FILESERVER_ROOT/k3s/1.33/install.sh" "$FILESERVER_ROOT/k3s/1.35/install.sh"
chmod +x "$FILESERVER_ROOT/k3s/1.33/install.sh" "$FILESERVER_ROOT/k3s/1.35/install.sh"

###############################################################################
# k3s-selinux RPM
###############################################################################
log "=== Downloading k3s-selinux RPM ==="
download "${GITHUB_SELINUX}/${K3S_SELINUX_VERSION}/k3s-selinux-1.6-1.el9.noarch.rpm" \
         "$FILESERVER_ROOT/rpm/k3s-selinux-1.6-1.el9.noarch.rpm"

###############################################################################
# Helm binary
###############################################################################
log "=== Downloading Helm ==="
download "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
         "$FILESERVER_ROOT/helm/helm-${HELM_VERSION}-linux-amd64.tar.gz"

###############################################################################
# Rancher Helm chart
###############################################################################
log "=== Downloading Rancher Helm chart ==="
if [[ ! -f "$FILESERVER_ROOT/helm/rancher-${RANCHER_VERSION#v}.tgz" ]]; then
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update
    helm pull rancher-stable/rancher --version="${RANCHER_VERSION#v}" \
         --destination "$FILESERVER_ROOT/helm/"
fi

###############################################################################
# cert-manager Helm chart + CRDs
###############################################################################
log "=== Downloading cert-manager Helm chart ==="
if [[ ! -f "$FILESERVER_ROOT/helm/cert-manager-${CERTMGR_VERSION}.tgz" ]]; then
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update
    helm pull jetstack/cert-manager --version="${CERTMGR_VERSION}" \
         --destination "$FILESERVER_ROOT/helm/"
fi

download "${GITHUB_CERTMGR}/${CERTMGR_VERSION}/cert-manager.crds.yaml" \
         "$FILESERVER_ROOT/helm/cert-manager-crd.yaml"

###############################################################################
# Rancher image list and scripts
###############################################################################
log "=== Downloading Rancher image assets ==="
download "${GITHUB_RANCHER}/${RANCHER_VERSION}/rancher-images.txt" \
         "$FILESERVER_ROOT/images/rancher-images.txt"

download "${GITHUB_RANCHER}/${RANCHER_VERSION}/rancher-save-images.sh" \
         "$FILESERVER_ROOT/images/rancher-save-images.sh"

download "${GITHUB_RANCHER}/${RANCHER_VERSION}/rancher-load-images.sh" \
         "$FILESERVER_ROOT/images/rancher-load-images.sh"

chmod +x "$FILESERVER_ROOT/images/rancher-save-images.sh" \
         "$FILESERVER_ROOT/images/rancher-load-images.sh"

###############################################################################
# Add cert-manager images to rancher-images.txt
###############################################################################
log "=== Appending cert-manager images to image list ==="
cat >> "$FILESERVER_ROOT/images/rancher-images.txt" <<EOF
quay.io/jetstack/cert-manager-controller:${CERTMGR_VERSION}
quay.io/jetstack/cert-manager-webhook:${CERTMGR_VERSION}
quay.io/jetstack/cert-manager-cainjector:${CERTMGR_VERSION}
quay.io/jetstack/cert-manager-ctl:${CERTMGR_VERSION}
quay.io/jetstack/cert-manager-acmesolver:${CERTMGR_VERSION}
EOF
sort -u "$FILESERVER_ROOT/images/rancher-images.txt" -o "$FILESERVER_ROOT/images/rancher-images.txt"

###############################################################################
# Verify checksums for k3s binaries
###############################################################################
log "=== Verifying k3s checksums ==="
for ver in 1.33 1.35; do
    pushd "$FILESERVER_ROOT/k3s/$ver" > /dev/null
    if grep -E "^[a-f0-9]+\s+(k3s|k3s-airgap)" sha256sum-amd64.txt | sha256sum -c --status 2>/dev/null; then
        log "k3s $ver checksums: PASS"
    else
        warn "k3s $ver checksums: could not fully verify (some files may use .zst extension)"
        # Try manual verification
        if [[ -f k3s ]]; then
            expected=$(grep "  k3s$" sha256sum-amd64.txt | awk '{print $1}')
            actual=$(sha256sum k3s | awk '{print $1}')
            if [[ "$expected" == "$actual" ]]; then
                log "  k3s binary checksum: PASS"
            else
                warn "  k3s binary checksum: MISMATCH"
            fi
        fi
    fi
    popd > /dev/null
done

###############################################################################
# Pull and push core images to local registry
###############################################################################
log "=== Pushing cert-manager images to local registry ==="
CERTMGR_IMAGES=(
    "quay.io/jetstack/cert-manager-controller:${CERTMGR_VERSION}"
    "quay.io/jetstack/cert-manager-webhook:${CERTMGR_VERSION}"
    "quay.io/jetstack/cert-manager-cainjector:${CERTMGR_VERSION}"
    "quay.io/jetstack/cert-manager-ctl:${CERTMGR_VERSION}"
)

for img in "${CERTMGR_IMAGES[@]}"; do
    log "Pulling $img"
    docker pull "$img"
    # Tag for local registry — preserve full path
    local_tag="${REGISTRY}/${img}"
    docker tag "$img" "$local_tag"
    log "Pushing $local_tag"
    docker push "$local_tag"
done

###############################################################################
# Pull and push core Rancher images to local registry
# (minimal set — full set uses rancher-save-images.sh / rancher-load-images.sh)
###############################################################################
log "=== Pushing core Rancher images to local registry ==="
RANCHER_CORE_IMAGES=(
    "rancher/rancher:${RANCHER_VERSION}"
    "rancher/rancher-agent:${RANCHER_VERSION}"
    "rancher/rancher-webhook:v0.9.2"
    "rancher/shell:v0.6.1"
    "rancher/fleet:v0.14.2"
    "rancher/fleet-agent:v0.14.2"
)

for img in "${RANCHER_CORE_IMAGES[@]}"; do
    log "Pulling $img"
    docker pull "$img" || { warn "Failed to pull $img — may need version update"; continue; }
    local_tag="${REGISTRY}/${img}"
    docker tag "$img" "$local_tag"
    log "Pushing $local_tag"
    docker push "$local_tag" || { warn "Failed to push $local_tag"; continue; }
done

###############################################################################
# Summary
###############################################################################
echo ""
log "========================================="
log "  ARTEFACT STAGING COMPLETE"
log "========================================="
echo ""
log "Directory structure:"
find "$FILESERVER_ROOT" -maxdepth 3 -type f | sort | while read -r f; do
    size=$(du -h "$f" | awk '{print $1}')
    echo "  $size  ${f#$FILESERVER_ROOT/}"
done
echo ""
log "Registry images pushed:"
curl -s "http://${REGISTRY}/v2/_catalog" 2>/dev/null || warn "Cannot reach registry"
echo ""
log "Next step: Run 02-controller-install.sh on the controller node"
