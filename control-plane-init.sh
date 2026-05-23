#!/bin/bash
# Usage: bash -s -- <join_token> <lb_ip> <node_ip> <k8s_version> <cert_key> <cp_name> < control-plane-init.sh
set -euo pipefail

JOIN_TOKEN="$1"
LB_IP="$2"
NODE_IP="$3"
K8S_VERSION="$4"
CERT_KEY="$5"
CP_NAME="$6"

exec > >(tee /var/log/k8s-setup.log) 2>&1

# Disable swap (required by kubeadm)
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# Kernel modules for container networking
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

# Install containerd (replaces Docker which was removed in K8s 1.24)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y containerd apt-transport-https ca-certificates curl gpg

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Use systemd cgroup driver to match kubelet
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Add Kubernetes apt repository (pkgs.k8s.io replaces the deprecated apt.kubernetes.io)
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Initialise the first control plane with HA settings
# --control-plane-endpoint points to the load balancer so all nodes share one endpoint
# --upload-certs uploads encrypted certs to the cluster so additional CPs can fetch them
kubeadm init \
    --token "$JOIN_TOKEN" \
    --token-ttl 0 \
    --upload-certs \
    --certificate-key "$CERT_KEY" \
    --control-plane-endpoint "${LB_IP}:6443" \
    --apiserver-cert-extra-sans="${LB_IP},${NODE_IP}" \
    --pod-network-cidr=10.0.0.0/8 \
    --node-name="$CP_NAME" \
    --skip-phases=addon/kube-proxy

# Set up kubeconfig for the first non-root user (UID 1000)
USER_HOME=$(getent passwd 1000 | cut -d: -f6)
mkdir -p "$USER_HOME/.kube"
cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown 1000:1000 "$USER_HOME/.kube/config"

# Wait for the API server to be ready before applying manifests
until kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null; do
    echo "Waiting for API server to be ready..."
    sleep 5
done

# Install Cilium CNI with VXLAN tunnel
CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
    -o /tmp/cilium-linux-amd64.tar.gz
tar xzvf /tmp/cilium-linux-amd64.tar.gz -C /usr/local/bin
rm /tmp/cilium-linux-amd64.tar.gz

KUBECONFIG=/etc/kubernetes/admin.conf cilium install \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${LB_IP}" \
    --set k8sServicePort=6443

echo "Control plane $CP_NAME setup complete. Run: kubectl get nodes"
