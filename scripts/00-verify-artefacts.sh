#!/bin/bash
###############################################################################
# 00-verify-artefacts.sh
# Verifies all required offline artefacts are present and correct.
# Run on the file server host.
###############################################################################

FILESERVER_ROOT="${FILESERVER_ROOT:-/home/pb/fileserver}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }

check_file() {
    local path="$1"
    local desc="$2"
    local min_size="${3:-0}"
    if [[ -f "$path" ]]; then
        local size
        size=$(stat -c%s "$path" 2>/dev/null || echo 0)
        local human
        human=$(du -h "$path" | awk '{print $1}')
        if [[ $size -ge $min_size ]]; then
            check_pass "$desc ($human)"
        else
            check_fail "$desc — file too small ($human, expected >${min_size} bytes)"
        fi
    else
        check_fail "$desc — MISSING: $path"
    fi
}

echo ""
echo "============================================"
echo "  Offline Artefact Verification"
echo "============================================"
echo ""

###############################################################################
# k3s v1.33 artefacts
###############################################################################
echo "--- k3s v1.33 ---"
check_file "$FILESERVER_ROOT/k3s/1.33/k3s" \
    "k3s v1.33 binary" 50000000
check_file "$FILESERVER_ROOT/k3s/1.33/k3s-airgap-images-amd64.tar.zst" \
    "k3s v1.33 airgap images" 100000000
check_file "$FILESERVER_ROOT/k3s/1.33/sha256sum-amd64.txt" \
    "k3s v1.33 checksums" 100
check_file "$FILESERVER_ROOT/k3s/1.33/install.sh" \
    "k3s v1.33 install script" 10000

# Verify checksum
if [[ -f "$FILESERVER_ROOT/k3s/1.33/k3s" && -f "$FILESERVER_ROOT/k3s/1.33/sha256sum-amd64.txt" ]]; then
    expected=$(grep "  k3s$" "$FILESERVER_ROOT/k3s/1.33/sha256sum-amd64.txt" | awk '{print $1}')
    actual=$(sha256sum "$FILESERVER_ROOT/k3s/1.33/k3s" | awk '{print $1}')
    if [[ -n "$expected" && "$expected" == "$actual" ]]; then
        check_pass "k3s v1.33 binary checksum"
    else
        check_fail "k3s v1.33 binary checksum MISMATCH"
    fi
fi

###############################################################################
# k3s v1.35 artefacts
###############################################################################
echo ""
echo "--- k3s v1.35 ---"
check_file "$FILESERVER_ROOT/k3s/1.35/k3s" \
    "k3s v1.35 binary" 50000000
check_file "$FILESERVER_ROOT/k3s/1.35/k3s-airgap-images-amd64.tar.zst" \
    "k3s v1.35 airgap images" 100000000
check_file "$FILESERVER_ROOT/k3s/1.35/sha256sum-amd64.txt" \
    "k3s v1.35 checksums" 100
check_file "$FILESERVER_ROOT/k3s/1.35/install.sh" \
    "k3s v1.35 install script" 10000

if [[ -f "$FILESERVER_ROOT/k3s/1.35/k3s" && -f "$FILESERVER_ROOT/k3s/1.35/sha256sum-amd64.txt" ]]; then
    expected=$(grep "  k3s$" "$FILESERVER_ROOT/k3s/1.35/sha256sum-amd64.txt" | awk '{print $1}')
    actual=$(sha256sum "$FILESERVER_ROOT/k3s/1.35/k3s" | awk '{print $1}')
    if [[ -n "$expected" && "$expected" == "$actual" ]]; then
        check_pass "k3s v1.35 binary checksum"
    else
        check_fail "k3s v1.35 binary checksum MISMATCH"
    fi
fi

###############################################################################
# Helm charts
###############################################################################
echo ""
echo "--- Helm Charts & Tools ---"
check_file "$FILESERVER_ROOT/helm/helm-v3.20.0-linux-amd64.tar.gz" \
    "Helm v3.20.0 binary" 10000000
check_file "$FILESERVER_ROOT/helm/rancher-2.13.2.tgz" \
    "Rancher Helm chart v2.13.2" 5000
check_file "$FILESERVER_ROOT/helm/cert-manager-v1.11.0.tgz" \
    "cert-manager Helm chart v1.11.0" 5000
check_file "$FILESERVER_ROOT/helm/cert-manager-crd.yaml" \
    "cert-manager CRDs" 100000

###############################################################################
# RPMs
###############################################################################
echo ""
echo "--- RPM Packages ---"
check_file "$FILESERVER_ROOT/rpm/k3s-selinux-1.6-1.el9.noarch.rpm" \
    "k3s-selinux RPM" 10000

###############################################################################
# Rancher image assets
###############################################################################
echo ""
echo "--- Rancher Image Assets ---"
check_file "$FILESERVER_ROOT/images/rancher-images.txt" \
    "Rancher image list" 10000
check_file "$FILESERVER_ROOT/images/rancher-save-images.sh" \
    "rancher-save-images.sh" 1000
check_file "$FILESERVER_ROOT/images/rancher-load-images.sh" \
    "rancher-load-images.sh" 1000

if [[ -f "$FILESERVER_ROOT/images/rancher-images.txt" ]]; then
    img_count=$(wc -l < "$FILESERVER_ROOT/images/rancher-images.txt")
    check_pass "Image list contains ${img_count} images"
fi

###############################################################################
# Scripts
###############################################################################
echo ""
echo "--- Scripts ---"
for script in \
    01-download-artefacts.sh \
    01b-push-images.sh \
    02-controller-install.sh \
    03-worker-install.sh \
    04-verify.sh \
    05-install-rancher.sh \
    06-upgrade.sh \
    99-uninstall.sh \
    00-verify-artefacts.sh; do
    if [[ -f "$FILESERVER_ROOT/scripts/$script" ]]; then
        if [[ -x "$FILESERVER_ROOT/scripts/$script" ]]; then
            check_pass "$script (executable)"
        else
            check_warn "$script (exists but not executable)"
        fi
    else
        check_warn "$script — not found"
    fi
done

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} PASS${NC}, ${RED}${FAIL} FAIL${NC}, ${YELLOW}${WARN} WARN${NC}"
echo "============================================"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some required artefacts are missing. Run 01-download-artefacts.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}All artefacts verified. Ready for installation.${NC}"
    exit 0
fi
