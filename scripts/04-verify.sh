#!/bin/bash
###############################################################################
# 04-verify.sh
# Validates the full deployment: services, cluster, images, pods.
# Run on the controller node (192.168.66.198).
###############################################################################

REGISTRY="192.168.66.198:5000"
GITEA="192.168.66.198:8888"
NGINX="192.168.66.198:8080"

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

echo ""
echo "============================================"
echo "  K3s Offline Deployment Verification"
echo "============================================"
echo ""

###############################################################################
# Infrastructure Services
###############################################################################
echo "--- Infrastructure Services ---"

# Docker Registry
if curl -sf "http://${REGISTRY}/v2/_catalog" &>/dev/null; then
    repos=$(curl -sf "http://${REGISTRY}/v2/_catalog" | python3 -c "import sys,json; r=json.load(sys.stdin).get('repositories',[]); print(len(r))" 2>/dev/null || echo "?")
    check_pass "Docker Registry (:5000) — ${repos} repositories"
else
    check_fail "Docker Registry (:5000) — not reachable"
fi

# Gitea
if curl -sf "http://${GITEA}" -o /dev/null; then
    check_pass "Gitea (:8888) — accessible"
else
    check_warn "Gitea (:8888) — not reachable (optional)"
fi

# Nginx File Server
if curl -sf "http://${NGINX}" -o /dev/null; then
    check_pass "Nginx File Server (:8080) — accessible"
else
    check_fail "Nginx File Server (:8080) — not reachable"
fi

# Portainer
if curl -sf "http://192.168.66.198:9090" -o /dev/null; then
    check_pass "Portainer (:9090) — accessible"
else
    check_warn "Portainer (:9090) — not reachable (optional)"
fi

# Dozzle
if curl -sf "http://192.168.66.198:9999" -o /dev/null; then
    check_pass "Dozzle (:9999) — accessible"
else
    check_warn "Dozzle (:9999) — not reachable (optional)"
fi

###############################################################################
# k3s Cluster
###############################################################################
echo ""
echo "--- k3s Cluster ---"

# k3s binary
if command -v k3s &>/dev/null; then
    ver=$(k3s --version 2>/dev/null | head -1)
    check_pass "k3s binary — $ver"
else
    check_fail "k3s binary — not found"
fi

# k3s service
if systemctl is-active --quiet k3s 2>/dev/null; then
    check_pass "k3s service — active"
elif systemctl is-active --quiet k3s-agent 2>/dev/null; then
    check_pass "k3s-agent service — active"
else
    check_fail "k3s service — not running"
fi

# kubectl get nodes
if command -v k3s &>/dev/null; then
    if k3s kubectl get nodes &>/dev/null; then
        node_count=$(k3s kubectl get nodes --no-headers 2>/dev/null | wc -l)
        ready_count=$(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
        check_pass "Cluster nodes — ${ready_count}/${node_count} Ready"
        echo ""
        k3s kubectl get nodes -o wide 2>/dev/null | sed 's/^/    /'
        echo ""
    else
        check_fail "kubectl get nodes — cannot connect to cluster"
    fi
fi

###############################################################################
# Container Images (crictl)
###############################################################################
echo "--- Container Images ---"

if command -v k3s &>/dev/null && k3s crictl images &>/dev/null; then
    img_count=$(k3s crictl images --no-trunc 2>/dev/null | tail -n +2 | wc -l)
    check_pass "Container images loaded — ${img_count} images"
    echo ""
    k3s crictl images 2>/dev/null | head -20 | sed 's/^/    /'
    if [[ $img_count -gt 20 ]]; then
        echo "    ... (${img_count} total, showing first 20)"
    fi
    echo ""
else
    check_warn "crictl — cannot list images (k3s may not be running)"
fi

###############################################################################
# Pods
###############################################################################
echo "--- Pods ---"

if command -v k3s &>/dev/null && k3s kubectl get pods -A &>/dev/null; then
    total=$(k3s kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    running=$(k3s kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || true)
    completed=$(k3s kubectl get pods -A --no-headers 2>/dev/null | grep -c "Completed" || true)
    other=$((total - running - completed))

    if [[ $other -eq 0 ]]; then
        check_pass "Pods — ${running} Running, ${completed} Completed (${total} total)"
    else
        check_warn "Pods — ${running} Running, ${completed} Completed, ${other} other (${total} total)"
    fi
    echo ""
    k3s kubectl get pods -A 2>/dev/null | sed 's/^/    /'
    echo ""
else
    check_warn "Cannot list pods"
fi

###############################################################################
# Airgap Files
###############################################################################
echo "--- Airgap Artefacts ---"

for ver in 1.33 1.35; do
    dir="/home/pb/fileserver/k3s/${ver}"
    if [[ -d "$dir" ]]; then
        files=$(ls "$dir" 2>/dev/null | wc -l)
        if [[ -f "$dir/k3s" && -f "$dir/install.sh" ]]; then
            check_pass "k3s ${ver} artefacts — ${files} files staged"
        else
            check_warn "k3s ${ver} artefacts — directory exists but incomplete"
        fi
    else
        check_warn "k3s ${ver} artefacts — not staged yet"
    fi
done

# Helm charts
if [[ -d "/home/pb/fileserver/helm" ]]; then
    helm_files=$(ls /home/pb/fileserver/helm/ 2>/dev/null | wc -l)
    check_pass "Helm charts — ${helm_files} files"
else
    check_warn "Helm charts — not staged"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} PASS${NC}, ${RED}${FAIL} FAIL${NC}, ${YELLOW}${WARN} WARN${NC}"
echo "============================================"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
