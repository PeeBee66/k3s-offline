#!/bin/bash
set -euo pipefail

###############################################################################
# 01-download-artefacts.sh
# Downloads all k3s, Helm, Rancher, and cert-manager artefacts for offline use.
# Run this on an internet-connected machine.
# Does NOT push images to registry (see 01b-push-images.sh for that).
###############################################################################

FILESERVER_ROOT="${FILESERVER_ROOT:-/home/pb/fileserver}"

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

log()  { echo -e "${GREEN}[DOWNLOAD]${NC} $*"; }
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
log "Creating directory structure..."
mkdir -p "$FILESERVER_ROOT"/{k3s/1.33,k3s/1.35,helm,rpm,images,scripts,repos}

###############################################################################
log "=== k3s v1.33 artefacts ==="
download "${GITHUB_K3S}/${K3S_V133_ENC}/k3s" \
         "$FILESERVER_ROOT/k3s/1.33/k3s"
download "${GITHUB_K3S}/${K3S_V133_ENC}/k3s-airgap-images-amd64.tar.zst" \
         "$FILESERVER_ROOT/k3s/1.33/k3s-airgap-images-amd64.tar.zst"
download "${GITHUB_K3S}/${K3S_V133_ENC}/sha256sum-amd64.txt" \
         "$FILESERVER_ROOT/k3s/1.33/sha256sum-amd64.txt"

###############################################################################
log "=== k3s v1.35 artefacts ==="
download "${GITHUB_K3S}/${K3S_V135_ENC}/k3s" \
         "$FILESERVER_ROOT/k3s/1.35/k3s"
download "${GITHUB_K3S}/${K3S_V135_ENC}/k3s-airgap-images-amd64.tar.zst" \
         "$FILESERVER_ROOT/k3s/1.35/k3s-airgap-images-amd64.tar.zst"
download "${GITHUB_K3S}/${K3S_V135_ENC}/sha256sum-amd64.txt" \
         "$FILESERVER_ROOT/k3s/1.35/sha256sum-amd64.txt"

###############################################################################
log "=== k3s install script ==="
download "https://get.k3s.io" "$FILESERVER_ROOT/k3s/1.33/install.sh"
cp "$FILESERVER_ROOT/k3s/1.33/install.sh" "$FILESERVER_ROOT/k3s/1.35/install.sh"
chmod +x "$FILESERVER_ROOT/k3s/1.33/install.sh" "$FILESERVER_ROOT/k3s/1.35/install.sh"

###############################################################################
log "=== k3s-selinux RPM ==="
download "${GITHUB_SELINUX}/${K3S_SELINUX_VERSION}/k3s-selinux-1.6-1.el9.noarch.rpm" \
         "$FILESERVER_ROOT/rpm/k3s-selinux-1.6-1.el9.noarch.rpm"

###############################################################################
log "=== Helm binary ==="
download "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
         "$FILESERVER_ROOT/helm/helm-${HELM_VERSION}-linux-amd64.tar.gz"

###############################################################################
log "=== Rancher Helm chart ==="
if [[ ! -f "$FILESERVER_ROOT/helm/rancher-${RANCHER_VERSION#v}.tgz" ]]; then
    if command -v helm &>/dev/null; then
        helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
        helm repo update
        helm pull rancher-stable/rancher --version="${RANCHER_VERSION#v}" \
             --destination "$FILESERVER_ROOT/helm/"
    else
        warn "helm not installed — cannot pull rancher chart. Install helm first."
    fi
fi

###############################################################################
log "=== cert-manager Helm chart + CRDs ==="
if [[ ! -f "$FILESERVER_ROOT/helm/cert-manager-${CERTMGR_VERSION}.tgz" ]]; then
    if command -v helm &>/dev/null; then
        helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
        helm repo update
        helm pull jetstack/cert-manager --version="${CERTMGR_VERSION}" \
             --destination "$FILESERVER_ROOT/helm/"
    else
        warn "helm not installed — cannot pull cert-manager chart."
    fi
fi
download "${GITHUB_CERTMGR}/${CERTMGR_VERSION}/cert-manager.crds.yaml" \
         "$FILESERVER_ROOT/helm/cert-manager-crd.yaml"

###############################################################################
log "=== Rancher image assets ==="
download "${GITHUB_RANCHER}/${RANCHER_VERSION}/rancher-images.txt" \
         "$FILESERVER_ROOT/images/rancher-images.txt"
download "${GITHUB_RANCHER}/${RANCHER_VERSION}/rancher-save-images.sh" \
         "$FILESERVER_ROOT/images/rancher-save-images.sh"
download "${GITHUB_RANCHER}/${RANCHER_VERSION}/rancher-load-images.sh" \
         "$FILESERVER_ROOT/images/rancher-load-images.sh"
chmod +x "$FILESERVER_ROOT/images/rancher-save-images.sh" \
         "$FILESERVER_ROOT/images/rancher-load-images.sh"

# Append cert-manager images
log "=== Appending cert-manager images to image list ==="
for img in \
    "quay.io/jetstack/cert-manager-controller:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-webhook:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-cainjector:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-ctl:${CERTMGR_VERSION}" \
    "quay.io/jetstack/cert-manager-acmesolver:${CERTMGR_VERSION}"; do
    grep -qxF "$img" "$FILESERVER_ROOT/images/rancher-images.txt" 2>/dev/null || \
        echo "$img" >> "$FILESERVER_ROOT/images/rancher-images.txt"
done
sort -u "$FILESERVER_ROOT/images/rancher-images.txt" -o "$FILESERVER_ROOT/images/rancher-images.txt"

###############################################################################
log "=== Verifying k3s checksums ==="
for ver in 1.33 1.35; do
    if [[ -f "$FILESERVER_ROOT/k3s/$ver/k3s" && -f "$FILESERVER_ROOT/k3s/$ver/sha256sum-amd64.txt" ]]; then
        expected=$(grep "  k3s$" "$FILESERVER_ROOT/k3s/$ver/sha256sum-amd64.txt" | awk '{print $1}')
        actual=$(sha256sum "$FILESERVER_ROOT/k3s/$ver/k3s" | awk '{print $1}')
        if [[ "$expected" == "$actual" ]]; then
            log "k3s $ver binary checksum: PASS"
        else
            warn "k3s $ver binary checksum: MISMATCH"
        fi
    fi
done

###############################################################################
echo ""
log "========================================="
log "  DOWNLOAD COMPLETE"
log "========================================="
echo ""
log "Files staged at: $FILESERVER_ROOT"
find "$FILESERVER_ROOT" -maxdepth 3 -type f ! -path '*/.git/*' | sort | while read -r f; do
    size=$(du -h "$f" | awk '{print $1}')
    echo "  $size  ${f#$FILESERVER_ROOT/}"
done
echo ""
log "Next: Run 00-verify-artefacts.sh to verify, then 01b-push-images.sh to push to registry (testing only)"
