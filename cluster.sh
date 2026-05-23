#!/usr/bin/env bash
# cluster.sh — end-to-end provision or destroy of the scaleaway Kubernetes cluster
#
# Usage:
#   ./cluster.sh up   [--stack dev] [--key ~/.ssh/id_rsa]
#   ./cluster.sh down [--stack dev]
#
# Environment variables (alternative to .envrc):
#   SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_PROJECT_ID

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
STACK="dev"
SSH_KEY=""           # auto-detect if empty
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
CMD="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack) STACK="$2"; shift 2 ;;
        --key)   SSH_KEY="$2"; shift 2 ;;
        *)       die "Unknown option: $1" ;;
    esac
done

[[ "$CMD" == "up" || "$CMD" == "down" ]] || {
    echo "Usage: $0 <up|down> [--stack <name>] [--key <ssh-private-key>]"
    exit 1
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
    local missing=()
    for tool in pulumi jq ssh scp ssh-keygen; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"

    [[ -n "${SCW_ACCESS_KEY:-}"         ]] || die "SCW_ACCESS_KEY is not set"
    [[ -n "${SCW_SECRET_KEY:-}"         ]] || die "SCW_SECRET_KEY is not set"
    [[ -n "${SCW_DEFAULT_PROJECT_ID:-}" ]] || warn "SCW_DEFAULT_PROJECT_ID is not set (may be fine for single-project accounts)"
}

# ── Python venv activation ────────────────────────────────────────────────────
activate_venv() {
    if [[ -z "${VIRTUAL_ENV:-}" ]]; then
        local venv="$REPO_DIR/venv"
        [[ -d "$venv" ]] || die "venv not found at $venv — run: python -m venv venv && pip install -r requirements.txt"
        # shellcheck disable=SC1091
        source "$venv/bin/activate"
        ok "Activated Python venv"
    fi
}

# ── SSH helpers ───────────────────────────────────────────────────────────────
ssh_opts() {
    local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
    [[ -n "$SSH_KEY" ]] && opts="$opts -i $SSH_KEY"
    echo "$opts"
}

wait_for_ssh() {
    local ip="$1"
    local max_attempts=30   # 5 minutes
    log "Waiting for SSH on $ip ..."
    for i in $(seq 1 "$max_attempts"); do
        # shellcheck disable=SC2086
        if ssh $(ssh_opts) root@"$ip" true 2>/dev/null; then
            ok "SSH ready on $ip"
            return 0
        fi
        [[ $i -lt $max_attempts ]] && sleep 10
    done
    die "SSH never became available on $ip after $((max_attempts * 10))s"
}

# ── Provision (up) ────────────────────────────────────────────────────────────
cmd_up() {
    cd "$REPO_DIR"
    check_prereqs
    activate_venv

    # ── 1. Pulumi stack ───────────────────────────────────────────────────────
    log "Selecting Pulumi stack '$STACK' (creating if absent) ..."
    pulumi stack select "$STACK" --create 2>/dev/null || pulumi stack select "$STACK"

    # ── 2. Provision infrastructure ───────────────────────────────────────────
    log "Running pulumi up ..."
    pulumi up --yes --stack "$STACK"
    ok "Infrastructure provisioned"

    # ── 3. Export IPs and bootstrap commands ─────────────────────────────────
    log "Exporting stack outputs ..."
    pulumi stack output control_plane_ips --json > cp-ips.json
    pulumi stack output worker_ips        --json > worker-ips.json
    pulumi stack output control_plane_setup_commands --show-secrets --json > cp-commands.json
    pulumi stack output worker_setup_commands        --show-secrets --json > worker-commands.json
    ok "Stack outputs written to cp-ips.json, worker-ips.json, cp-commands.json, worker-commands.json"

    # Discover node names from outputs
    local cp_nodes worker_nodes
    cp_nodes=$(jq -r 'keys[]' cp-ips.json | sort)
    worker_nodes=$(jq -r 'keys[]' worker-ips.json | sort)
    local first_cp
    first_cp=$(echo "$cp_nodes" | head -1)

    # ── 4. Bootstrap first control plane (kubeadm init) ───────────────────────
    local cp01_ip cp01_cmd
    cp01_ip=$(jq -r --arg n "$first_cp" '.[$n]' cp-ips.json)
    cp01_cmd=$(jq -r --arg n "$first_cp" '.[$n]' cp-commands.json)

    ssh-keygen -R "$cp01_ip" 2>/dev/null || true
    wait_for_ssh "$cp01_ip"

    log "Bootstrapping first control plane $first_cp ($cp01_ip) — this takes ~5 min ..."
    # shellcheck disable=SC2086
    ssh $(ssh_opts) root@"$cp01_ip" "$cp01_cmd" < "$REPO_DIR/control-plane-init.sh"
    ok "First control plane $first_cp is up"

    # ── 5. Bootstrap additional control planes sequentially ──────────────────
    # etcd quorum is sensitive to concurrent member additions — join one at a time
    local additional_cps
    additional_cps=$(echo "$cp_nodes" | tail -n +2)

    if [[ -n "$additional_cps" ]]; then
        # Use fd 3 for the loop — ssh calls inside (wait_for_ssh, the join itself)
        # read from fd 0 and would steal lines from the here-string if we used fd 0.
        while IFS= read -r -u3 node; do
            local ip cmd
            ip=$(jq -r --arg n "$node" '.[$n]' cp-ips.json)
            cmd=$(jq -r --arg n "$node" '.[$n]' cp-commands.json)
            ssh-keygen -R "$ip" 2>/dev/null || true
            wait_for_ssh "$ip"
            log "Joining $node ($ip) ..."
            # shellcheck disable=SC2086
            ssh $(ssh_opts) root@"$ip" "$cmd" < "$REPO_DIR/control-plane-join.sh" \
                || die "$node failed to join"
            ok "$node joined"
        done 3<<< "$additional_cps"
        ok "All additional control planes joined"
    fi

    # ── 6. Bootstrap workers in parallel ─────────────────────────────────────
    pids=()
    if [[ -n "$worker_nodes" ]]; then
        log "Bootstrapping workers in parallel ..."
        while IFS= read -r -u3 node; do
            local ip cmd
            ip=$(jq -r --arg n "$node" '.[$n]' worker-ips.json)
            cmd=$(jq -r --arg n "$node" '.[$n]' worker-commands.json)
            ssh-keygen -R "$ip" 2>/dev/null || true
            wait_for_ssh "$ip"
            log "  Starting $node ($ip) in background ..."
            # shellcheck disable=SC2086
            ssh $(ssh_opts) root@"$ip" "$cmd" < "$REPO_DIR/worker-join.sh" &
            pids+=($!)
        done 3<<< "$worker_nodes"

        for pid in "${pids[@]}"; do
            wait "$pid" || die "A worker bootstrap failed (pid $pid)"
        done
        ok "All workers joined"
    fi

    # ── 7. Fetch kubeconfig ───────────────────────────────────────────────────
    log "Fetching kubeconfig from $first_cp ($cp01_ip) ..."
    # shellcheck disable=SC2086
    scp $(ssh_opts) root@"$cp01_ip":/etc/kubernetes/admin.conf "$REPO_DIR/kubeconfig-scaleaway.yaml"
    ok "kubeconfig saved to kubeconfig-scaleaway.yaml"

    # ── 8. Verify cluster ─────────────────────────────────────────────────────
    log "Verifying cluster (waiting up to 2 min for all nodes to be Ready) ..."
    local attempts=0
    export KUBECONFIG="$REPO_DIR/kubeconfig-scaleaway.yaml"
    until kubectl get nodes 2>/dev/null | grep -v "NotReady" | grep -qc "Ready" || [[ $attempts -ge 24 ]]; do
        sleep 5
        (( attempts++ )) || true
    done
    kubectl get nodes -o wide || warn "kubectl get nodes failed — cluster may still be coming up"

    echo ""
    ok "Cluster is ready!"
    echo -e "  ${CYAN}export KUBECONFIG=$REPO_DIR/kubeconfig-scaleaway.yaml${NC}"
    echo ""
    warn "cp-commands.json and worker-commands.json contain secrets — delete them when done:"
    echo "  rm -f cp-commands.json worker-commands.json"
}

# ── Destroy (down) ────────────────────────────────────────────────────────────
cmd_down() {
    cd "$REPO_DIR"
    check_prereqs
    activate_venv

    log "Destroying stack '$STACK' ..."
    pulumi destroy --yes --stack "$STACK"
    ok "All Scaleway resources destroyed"

    log "Cleaning up generated files ..."
    rm -f cp-ips.json worker-ips.json cp-commands.json worker-commands.json
    ok "Local JSON files removed"
    warn "kubeconfig-scaleaway.yaml left in place (now stale — delete manually if desired)"
    warn "Pulumi state preserved at ~/.pulumi-local — re-run './cluster.sh up' to reprovision with same join token"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    up)   cmd_up   ;;
    down) cmd_down ;;
esac
