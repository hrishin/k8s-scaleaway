# scaleaway — Self-Managed Kubernetes on Scaleway

Provisions a self-managed Kubernetes cluster on Scaleway using VM instances using Pulumi (Python). 
Spins up control-plane nodes behind a Scaleway Load Balancer and N worker nodes, then bootstraps the cluster via kubeadm over SSH. 
CNI is [Cilium](https://cilium.io) with VXLAN tunneling.
Default topology (configurable): **3 control-plane nodes + 1 worker**, `PLAY2-MICRO` instances, `fr-par-2`.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Pulumi CLI](https://www.pulumi.com/docs/install/) | IaC engine |
| Python 3.10+ | Runtime for the Pulumi program |
| [jq](https://jqlang.github.io/jq/) | Parse JSON stack outputs |
| Scaleway account | API keys + project ID |
| SSH key registered in Scaleway | Access to provisioned instances |

Pulumi state is stored **locally** at `~/.pulumi-local` — no Pulumi Cloud account required.

---

## Quick start

### 1. Clone and configure credentials

```bash
git clone <repo-url> scaleaway
cd scaleaway
```

Edit `.envrc` with your Scaleway credentials:

```bash
export SCW_ACCESS_KEY="<your-access-key>"
export SCW_SECRET_KEY="<your-secret-key>"
export SCW_DEFAULT_PROJECT_ID="<your-project-id>"

source venv/bin/activate
```

Then either `direnv allow` (if you use direnv) or `source .envrc` manually each session.

### 2. Install Python dependencies

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 3. Provision the cluster

```bash
./cluster.sh up
```

This single command:
1. Runs `pulumi up` to create instances and load balancer
2. Waits for SSH to come up on each node
3. Bootstraps the first control plane (`kubeadm init` + Cilium CNI)
4. Joins additional control planes in parallel
5. Joins workers in parallel
6. Fetches `kubeconfig-scaleaway.yaml` from the first control plane

Expect ~10 minutes end-to-end.

### 4. Access the cluster

```bash
export KUBECONFIG="$PWD/kubeconfig-scaleaway.yaml"
kubectl get nodes -o wide
```

All nodes should show `Ready` once Cilium finishes its rollout:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
```

### 5. Tear down

```bash
./cluster.sh down
```

Destroys all Scaleway resources (instances, load balancer, IPs) and removes generated JSON files. Pulumi state is preserved locally so you can re-provision later with the same join token.

---

## cluster.sh options

```
./cluster.sh <up|down> [--stack <name>] [--key <ssh-private-key-path>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--stack` | `dev` | Pulumi stack name |
| `--key` | SSH agent / default key | Path to SSH private key for node access |

---

## Stack configuration

Stack config lives in `Pulumi.dev.yaml`. Override any value with:

```bash
pulumi config set workerCount 3
pulumi config set instanceType PLAY2-NANO
pulumi config set k8sVersion 1.34
```

| Key | Default | Description |
|-----|---------|-------------|
| `zone` | `fr-par-2` | Scaleway availability zone |
| `instanceType` | `PLAY2-MICRO` | Instance commercial type |
| `controlPlaneCount` | `3` | Number of control-plane nodes |
| `workerCount` | `1` | Number of worker nodes |
| `lbType` | `LB-S` | Load balancer SKU |
| `k8sVersion` | `1.34` | Kubernetes minor version |

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────┐
│  Scaleway LB    │  :6443 (TCP)
└────────┬────────┘
         │
   ┌─────┴──────┐
   ▼            ▼
[cp-01]      [cp-02/03]     ← kubeadm HA control plane
   │
   ├── etcd (embedded, replicated across all CPs)
   └── Cilium (VXLAN tunnel) installed on cluster init

[worker-01..N]  ← join via LB endpoint
```

- **Load balancer** fronts all control-plane API servers on port 6443 so workers and `kubectl` always have a stable endpoint.
- **Cilium** runs in VXLAN tunnel mode — no BGP or underlay configuration required.
- **Pulumi state** is local (`~/.pulumi-local`). Back it up if you need to manage the stack long-term.

---

## Manual bootstrapping (advanced)

If you need to re-run individual steps without `cluster.sh`, export the Pulumi outputs and drive the scripts directly:

```bash
pulumi stack output control_plane_ips --json > cp-ips.json
pulumi stack output worker_ips        --json > worker-ips.json
pulumi stack output control_plane_setup_commands --show-secrets --json > cp-commands.json
pulumi stack output worker_setup_commands        --show-secrets --json > worker-commands.json

# First control plane
CP01_IP=$(jq -r '.["control-plane-01"]' cp-ips.json)
CP01_CMD=$(jq -r '.["control-plane-01"]' cp-commands.json)
ssh root@"$CP01_IP" "$CP01_CMD" < control-plane-init.sh

# Additional control planes (parallel)
for node in control-plane-02 control-plane-03; do
    IP=$(jq -r --arg n "$node" '.[$n]' cp-ips.json)
    CMD=$(jq -r --arg n "$node" '.[$n]' cp-commands.json)
    ssh root@"$IP" "$CMD" < control-plane-join.sh &
done
wait

# Workers (parallel)
for node in worker-01; do
    IP=$(jq -r --arg n "$node" '.[$n]' worker-ips.json)
    CMD=$(jq -r --arg n "$node" '.[$n]' worker-commands.json)
    ssh root@"$IP" "$CMD" < worker-join.sh &
done
wait
```

> `cp-commands.json` and `worker-commands.json` contain secrets (join token, cert key) — delete them after bootstrapping.
