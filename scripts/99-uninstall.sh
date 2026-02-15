#!/bin/bash
set -euo pipefail

###############################################################################
# 99-uninstall.sh
# Fully removes k3s (server or agent) and restores clean state.
# Supports repeat testing cycles.
#
# Usage: sudo ./99-uninstall.sh [--reboot]
###############################################################################

DO_REBOOT=false
[[ "${1:-}" == "--reboot" ]] && DO_REBOOT=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[UNINSTALL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $(id -u) -eq 0 ]] || { err "Must run as root"; exit 1; }

echo ""
log "========================================="
log "  k3s Full Uninstall"
log "========================================="
echo ""

###############################################################################
# Step 1: Run official uninstall scripts
###############################################################################
log "=== Step 1: Running official uninstall scripts ==="

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    log "Running k3s-uninstall.sh (server)..."
    /usr/local/bin/k3s-uninstall.sh || warn "k3s-uninstall.sh returned non-zero"
elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
    log "Running k3s-agent-uninstall.sh (agent)..."
    /usr/local/bin/k3s-agent-uninstall.sh || warn "k3s-agent-uninstall.sh returned non-zero"
else
    warn "No official uninstall script found — performing manual cleanup"

    # Stop services
    systemctl stop k3s k3s-agent 2>/dev/null || true
    systemctl disable k3s k3s-agent 2>/dev/null || true

    # Remove service files
    rm -f /etc/systemd/system/k3s.service
    rm -f /etc/systemd/system/k3s-agent.service
    rm -f /etc/systemd/system/k3s.service.env
    rm -f /etc/systemd/system/k3s-agent.service.env
    systemctl daemon-reload

    # Remove binaries and symlinks
    rm -f /usr/local/bin/k3s
    rm -f /usr/local/bin/kubectl
    rm -f /usr/local/bin/crictl
    rm -f /usr/local/bin/ctr
    rm -f /usr/local/bin/k3s-uninstall.sh
    rm -f /usr/local/bin/k3s-agent-uninstall.sh
fi

###############################################################################
# Step 2: Remove data directories
###############################################################################
log "=== Step 2: Removing data directories ==="

if [[ -d /var/lib/rancher/k3s ]]; then
    rm -rf /var/lib/rancher/k3s
    log "Removed /var/lib/rancher/k3s"
fi

if [[ -d /etc/rancher/k3s ]]; then
    rm -rf /etc/rancher/k3s
    log "Removed /etc/rancher/k3s"
fi

# Remove rancher parent dirs if empty
rmdir /var/lib/rancher 2>/dev/null || true
rmdir /etc/rancher 2>/dev/null || true

###############################################################################
# Step 3: Clean up networking
###############################################################################
log "=== Step 3: Cleaning up networking ==="

# Remove CNI config
rm -rf /var/lib/cni/ 2>/dev/null || true
rm -rf /etc/cni/ 2>/dev/null || true

# Remove flannel interfaces
for iface in flannel.1 cni0 flannel-v6.1 flannel-wg flannel-wg-v6; do
    if ip link show "$iface" &>/dev/null; then
        ip link delete "$iface" 2>/dev/null || true
        log "Removed interface: $iface"
    fi
done

# Remove veth pairs (k3s containers)
for veth in $(ip link show 2>/dev/null | grep -oP 'veth\w+' | sort -u); do
    ip link delete "$veth" 2>/dev/null || true
done

# Flush iptables rules added by k3s
log "Flushing iptables rules..."
iptables-save 2>/dev/null | grep -i "KUBE\|CNI\|FLANNEL" &>/dev/null && {
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    log "iptables flushed"
} || log "No k3s iptables rules found"

# Same for ip6tables
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -t nat -X 2>/dev/null || true

###############################################################################
# Step 4: Remove k3s-selinux
###############################################################################
log "=== Step 4: Removing k3s-selinux ==="
if rpm -q k3s-selinux &>/dev/null; then
    rpm -e k3s-selinux || warn "Failed to remove k3s-selinux"
    log "k3s-selinux removed"
else
    log "k3s-selinux not installed"
fi

###############################################################################
# Step 5: Clean up remaining files
###############################################################################
log "=== Step 5: Final cleanup ==="
rm -rf /var/log/containers/ 2>/dev/null || true
rm -rf /var/log/pods/ 2>/dev/null || true
rm -f /etc/sysconfig/k3s 2>/dev/null || true
rm -f /etc/default/k3s 2>/dev/null || true

###############################################################################
# Verification
###############################################################################
log "=== Verification ==="
CLEAN=true

if command -v k3s &>/dev/null; then
    warn "k3s binary still found at $(which k3s)"
    CLEAN=false
fi

if [[ -d /var/lib/rancher/k3s ]]; then
    warn "/var/lib/rancher/k3s still exists"
    CLEAN=false
fi

if [[ -d /etc/rancher/k3s ]]; then
    warn "/etc/rancher/k3s still exists"
    CLEAN=false
fi

if systemctl is-active --quiet k3s 2>/dev/null || systemctl is-active --quiet k3s-agent 2>/dev/null; then
    warn "k3s service still running"
    CLEAN=false
fi

if $CLEAN; then
    log "System is clean — ready for fresh install"
else
    warn "Some remnants remain — a reboot may be needed"
fi

###############################################################################
# Optional reboot
###############################################################################
if $DO_REBOOT; then
    log "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi

echo ""
log "Uninstall complete"
