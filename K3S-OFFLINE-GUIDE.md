# K3s Offline Deployment Guide — RHEL 9

## Environment

| Node | IP | Hostname | Role |
|---|---|---|---|
| Controller | 192.168.66.198 | RHEL-TEST-01 | k3s server + support services |
| Worker | 192.168.66.199 | RHEL-TEST-02 | k3s agent |

| Service | Port | Data Path |
|---|---|---|
| Docker Registry | 5000 | /home/pb/registry_data/ |
| Nginx File Server | 8080 | /home/pb/fileserver/ |
| Gitea | 8888 (web), 2222 (SSH) | /home/pb/gitea_data/ |
| Portainer | 9090 | /home/pb/portainer_data/ |
| Dozzle | 9999 | stateless |

## Version Pinning

| Component | Version |
|---|---|
| k3s (initial) | v1.33.8+k3s1 |
| k3s (upgrade) | v1.35.1+k3s1 |
| Rancher | v2.13.2 |
| cert-manager | v1.11.0 |
| Helm | v3.20.0 |
| k3s-selinux | 1.6-1.el9 |

---

## Manual Download Guide

If the staging script (01-stage-artefacts.sh) cannot be used, download these files manually from an internet-connected machine and place them in the paths shown.

### k3s v1.33.8 Files

Download from: `https://github.com/k3s-io/k3s/releases/tag/v1.33.8%2Bk3s1`

| File | URL | Place At |
|---|---|---|
| k3s binary | `https://github.com/k3s-io/k3s/releases/download/v1.33.8%2Bk3s1/k3s` | `/home/pb/fileserver/k3s/1.33/k3s` |
| Airgap images | `https://github.com/k3s-io/k3s/releases/download/v1.33.8%2Bk3s1/k3s-airgap-images-amd64.tar.zst` | `/home/pb/fileserver/k3s/1.33/k3s-airgap-images-amd64.tar.zst` |
| Checksums | `https://github.com/k3s-io/k3s/releases/download/v1.33.8%2Bk3s1/sha256sum-amd64.txt` | `/home/pb/fileserver/k3s/1.33/sha256sum-amd64.txt` |
| Install script | `https://get.k3s.io` | `/home/pb/fileserver/k3s/1.33/install.sh` |

```bash
# Manual download commands
mkdir -p /home/pb/fileserver/k3s/1.33
cd /home/pb/fileserver/k3s/1.33
curl -fSLO "https://github.com/k3s-io/k3s/releases/download/v1.33.8%2Bk3s1/k3s"
curl -fSLO "https://github.com/k3s-io/k3s/releases/download/v1.33.8%2Bk3s1/k3s-airgap-images-amd64.tar.zst"
curl -fSL -o sha256sum-amd64.txt "https://github.com/k3s-io/k3s/releases/download/v1.33.8%2Bk3s1/sha256sum-amd64.txt"
curl -fSL -o install.sh "https://get.k3s.io"
chmod +x install.sh k3s
```

### k3s v1.35.1 Files (for upgrade)

Download from: `https://github.com/k3s-io/k3s/releases/tag/v1.35.1%2Bk3s1`

```bash
mkdir -p /home/pb/fileserver/k3s/1.35
cd /home/pb/fileserver/k3s/1.35
curl -fSLO "https://github.com/k3s-io/k3s/releases/download/v1.35.1%2Bk3s1/k3s"
curl -fSLO "https://github.com/k3s-io/k3s/releases/download/v1.35.1%2Bk3s1/k3s-airgap-images-amd64.tar.zst"
curl -fSL -o sha256sum-amd64.txt "https://github.com/k3s-io/k3s/releases/download/v1.35.1%2Bk3s1/sha256sum-amd64.txt"
curl -fSL -o install.sh "https://get.k3s.io"
chmod +x install.sh k3s
```

### Helm Binary

```bash
mkdir -p /home/pb/fileserver/helm
curl -fSL -o /home/pb/fileserver/helm/helm-v3.20.0-linux-amd64.tar.gz \
    "https://get.helm.sh/helm-v3.20.0-linux-amd64.tar.gz"
```

### Rancher Helm Chart

Requires helm CLI on a connected machine:

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
helm pull rancher-stable/rancher --version=2.13.2 --destination /home/pb/fileserver/helm/
```

### cert-manager Helm Chart + CRDs

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm pull jetstack/cert-manager --version=v1.11.0 --destination /home/pb/fileserver/helm/

curl -fSL -o /home/pb/fileserver/helm/cert-manager-crd.yaml \
    "https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.crds.yaml"
```

### k3s-selinux RPM

```bash
mkdir -p /home/pb/fileserver/rpm
curl -fSL -o /home/pb/fileserver/rpm/k3s-selinux-1.6-1.el9.noarch.rpm \
    "https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.stable.1/k3s-selinux-1.6-1.el9.noarch.rpm"
```

### Rancher Image Assets

```bash
mkdir -p /home/pb/fileserver/images
curl -fSL -o /home/pb/fileserver/images/rancher-images.txt \
    "https://github.com/rancher/rancher/releases/download/v2.13.2/rancher-images.txt"
curl -fSL -o /home/pb/fileserver/images/rancher-save-images.sh \
    "https://github.com/rancher/rancher/releases/download/v2.13.2/rancher-save-images.sh"
curl -fSL -o /home/pb/fileserver/images/rancher-load-images.sh \
    "https://github.com/rancher/rancher/releases/download/v2.13.2/rancher-load-images.sh"
chmod +x /home/pb/fileserver/images/*.sh
```

### Container Images to Push to Registry

The local Docker daemon must be configured for insecure registry.
Add to `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["192.168.66.198:5000"]
}
```

Then `systemctl restart docker`.

#### cert-manager Images

```bash
REGISTRY="192.168.66.198:5000"
for img in \
    quay.io/jetstack/cert-manager-controller:v1.11.0 \
    quay.io/jetstack/cert-manager-webhook:v1.11.0 \
    quay.io/jetstack/cert-manager-cainjector:v1.11.0 \
    quay.io/jetstack/cert-manager-ctl:v1.11.0; do
    docker pull "$img"
    docker tag "$img" "${REGISTRY}/${img}"
    docker push "${REGISTRY}/${img}"
done
```

#### Rancher Core Images

```bash
REGISTRY="192.168.66.198:5000"
for img in \
    rancher/rancher:v2.13.2 \
    rancher/rancher-agent:v2.13.2 \
    rancher/rancher-webhook:v0.9.2 \
    rancher/shell:v0.6.1 \
    rancher/fleet:v0.14.2 \
    rancher/fleet-agent:v0.14.2; do
    docker pull "$img"
    docker tag "$img" "${REGISTRY}/${img}"
    docker push "${REGISTRY}/${img}"
done
```

#### Full Rancher Image Set (optional — 500+ images)

For a complete offline Rancher install with all features:

```bash
chmod +x /home/pb/fileserver/images/rancher-save-images.sh
./rancher-save-images.sh --image-list ./rancher-images.txt
# Produces rancher-images.tar.gz (very large)

# Load into registry:
chmod +x /home/pb/fileserver/images/rancher-load-images.sh
./rancher-load-images.sh --image-list ./rancher-images.txt --registry 192.168.66.198:5000
```

---

## Installation Process

### Prerequisites (both nodes)

- RHEL 9 with CentOS 9 Stream repos (if unregistered)
- User with sudo/root access
- Network connectivity between nodes
- `sshpass` installed on controller (for remote worker install)

### Firewall Ports Required

**Controller (192.168.66.198):**
- 6443/tcp — k3s API server
- 8472/udp — Flannel VXLAN
- 10250/tcp — kubelet metrics
- 51820/udp, 51821/udp — WireGuard (if used)
- 5000/tcp — Docker Registry
- 8080/tcp — Nginx file server
- 8888/tcp, 2222/tcp — Gitea
- 9090/tcp — Portainer
- 9999/tcp — Dozzle

**Worker (192.168.66.199):**
- 8472/udp — Flannel VXLAN
- 10250/tcp — kubelet metrics
- 51820/udp, 51821/udp — WireGuard

### Step 1: Stage Artefacts

```bash
# Automated (on internet-connected controller):
sudo bash /home/pb/fileserver/scripts/01-stage-artefacts.sh

# Or follow the manual download guide above
```

### Step 2: Install Controller

```bash
# On 192.168.66.198:
sudo bash /home/pb/fileserver/scripts/02-controller-install.sh
```

What the script does:
1. Downloads k3s binary, airgap images, install script from nginx (localhost:8080)
2. Verifies SHA256 checksum of k3s binary
3. Installs k3s-selinux RPM (if SELinux active)
4. Places k3s binary at `/usr/local/bin/k3s`
5. Places airgap images at `/var/lib/rancher/k3s/agent/images/`
6. Creates registry mirror config at `/etc/rancher/k3s/registries.yaml`
7. Opens firewall ports
8. Runs `INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh` with server flags
9. Waits for node to be Ready
10. Outputs the node join token

**Manual equivalent:**

```bash
# Place binary
sudo install -m 755 /home/pb/fileserver/k3s/1.33/k3s /usr/local/bin/k3s

# Place airgap images
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp /home/pb/fileserver/k3s/1.33/k3s-airgap-images-amd64.tar.zst \
    /var/lib/rancher/k3s/agent/images/

# Install SELinux policy
sudo rpm -ivh /home/pb/fileserver/rpm/k3s-selinux-1.6-1.el9.noarch.rpm

# Create registry config
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "http://192.168.66.198:5000"
  quay.io:
    endpoint:
      - "http://192.168.66.198:5000"
  ghcr.io:
    endpoint:
      - "http://192.168.66.198:5000"
configs:
  "192.168.66.198:5000":
    tls:
      insecure_skip_verify: true
EOF

# Open firewall
sudo firewall-cmd --permanent --add-port={6443/tcp,8472/udp,10250/tcp}
sudo firewall-cmd --reload

# Install k3s
INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_SKIP_SELINUX_RPM=true \
INSTALL_K3S_EXEC="server --node-ip=192.168.66.198 --disable=cloud-controller-manager --write-kubeconfig-mode=644 --tls-san=192.168.66.198" \
bash /home/pb/fileserver/k3s/1.33/install.sh

# Get token
cat /var/lib/rancher/k3s/server/node-token
```

### Step 3: Install Worker

```bash
# On 192.168.66.199 (or remotely via SSH from controller):
sudo K3S_TOKEN="<token-from-step-2>" bash /home/pb/fileserver/scripts/03-worker-install.sh

# Remote from controller:
sshpass -p 'Password20' scp scripts/03-worker-install.sh pb@192.168.66.199:/tmp/
sshpass -p 'Password20' ssh pb@192.168.66.199 \
    "echo 'Password20' | sudo -S K3S_TOKEN='<token>' bash /tmp/03-worker-install.sh"
```

### Step 4: Verify

```bash
sudo bash /home/pb/fileserver/scripts/04-verify.sh

# Or manually:
k3s kubectl get nodes -o wide
k3s kubectl get pods -A
k3s crictl images
curl -s http://192.168.66.198:5000/v2/_catalog
```

---

## Uninstall / Reset

```bash
# On controller:
sudo bash /home/pb/fileserver/scripts/99-uninstall.sh

# On worker:
sudo bash /home/pb/fileserver/scripts/99-uninstall.sh

# With reboot:
sudo bash /home/pb/fileserver/scripts/99-uninstall.sh --reboot
```

The uninstall script:
1. Runs official k3s-uninstall.sh / k3s-agent-uninstall.sh
2. Removes /var/lib/rancher/k3s, /etc/rancher/k3s
3. Cleans CNI interfaces (flannel, cni0, veth pairs)
4. Flushes iptables rules
5. Removes k3s-selinux RPM
6. Verifies clean state

---

## Upgrade Process (v1.33 to v1.35)

```bash
# On controller:
sudo bash /home/pb/fileserver/scripts/06-upgrade.sh 1.35
```

The script performs a rolling upgrade:
1. Downloads v1.35 binary + airgap images from nginx
2. Verifies checksum
3. Upgrades controller: replace binary, replace images, restart k3s, wait for Ready
4. SSHes to worker: copies files, replaces binary, restarts k3s-agent, waits for Ready
5. Validates all nodes show new version and workloads survived

---

## Rancher + cert-manager Install

```bash
# After cluster is validated:
sudo bash /home/pb/fileserver/scripts/05-install-rancher.sh
```

---

## File Inventory

```
/home/pb/fileserver/
├── k3s/
│   ├── 1.33/
│   │   ├── k3s                                  (72M)
│   │   ├── k3s-airgap-images-amd64.tar.zst     (175M)
│   │   ├── sha256sum-amd64.txt
│   │   └── install.sh
│   └── 1.35/
│       ├── k3s                                  (73M)
│       ├── k3s-airgap-images-amd64.tar.zst     (175M)
│       ├── sha256sum-amd64.txt
│       └── install.sh
├── helm/
│   ├── helm-v3.20.0-linux-amd64.tar.gz         (17M)
│   ├── rancher-2.13.2.tgz                      (20K)
│   ├── cert-manager-v1.11.0.tgz                (68K)
│   └── cert-manager-crd.yaml                   (380K)
├── rpm/
│   └── k3s-selinux-1.6-1.el9.noarch.rpm        (24K)
├── images/
│   ├── rancher-images.txt                       (552 images)
│   ├── rancher-save-images.sh
│   └── rancher-load-images.sh
├── scripts/
│   ├── 01-stage-artefacts.sh
│   ├── 02-controller-install.sh
│   ├── 03-worker-install.sh
│   ├── 04-verify.sh
│   ├── 05-install-rancher.sh
│   ├── 06-upgrade.sh
│   └── 99-uninstall.sh
└── K3S-OFFLINE-GUIDE.md                         (this file)
```

## Registry Contents (192.168.66.198:5000)

```
quay.io/jetstack/cert-manager-cainjector    v1.11.0
quay.io/jetstack/cert-manager-controller    v1.11.0
quay.io/jetstack/cert-manager-ctl           v1.11.0
quay.io/jetstack/cert-manager-webhook       v1.11.0
rancher/fleet                               v0.14.2
rancher/fleet-agent                         v0.14.2
rancher/rancher                             v2.13.2
rancher/rancher-agent                       v2.13.2
rancher/rancher-webhook                     v0.9.2
rancher/shell                               v0.6.1
```

## Lessons Learned

1. **Docker insecure registry**: Must add `{"insecure-registries": ["192.168.66.198:5000"]}` to `/etc/docker/daemon.json` before pushing images
2. **Firewall**: RHEL 9 firewalld blocks k3s ports by default — must open 6443/tcp, 8472/udp, 10250/tcp before worker can join
3. **RHEL unregistered**: CentOS 9 Stream repos work as a drop-in replacement for package access
4. **Helm charts**: Need helm CLI installed to pull charts (can't just curl them)
5. **Airgap images**: k3s loads .tar.zst from `/var/lib/rancher/k3s/agent/images/` automatically — no manual import needed
