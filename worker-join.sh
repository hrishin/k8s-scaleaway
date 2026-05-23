#!/bin/bash
# Usage: bash -s -- <join_token> <lb_ip> <k8s_version> <worker_name> < worker-join.sh
set -euo pipefail

JOIN_TOKEN="$1"
LB_IP="$2"
K8S_VERSION="$3"
WORKER_NAME="$4"

exec > >(tee /var/log/k8s-setup.log) 2>&1

# Disable swap
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# Kernel modules
cat > /etc/modules-load.d/k8s.conf << 'MODULES'
overlay
br_netfilter
MODULES
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

# Install containerd
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y containerd apt-transport-https ca-certificates curl gpg

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Add Kubernetes apt repository
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Join the cluster, retrying until the control plane is ready (up to 10 min)
joined=false
for i in $(seq 1 20); do
    if kubeadm join "${LB_IP}:6443" \
        --token "$JOIN_TOKEN" \
        --discovery-token-unsafe-skip-ca-verification \
        --node-name="$WORKER_NAME"; then
        joined=true
        break
    fi
    echo "Join attempt $i failed, retrying in 30s..."
    sleep 30
done
[[ "$joined" == true ]] || { echo "ERROR: $WORKER_NAME failed to join after 20 attempts"; exit 1; }

echo "Worker $WORKER_NAME joined the cluster."
