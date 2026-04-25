#!/usr/bin/env bash
# bootstrap.sh — Full cluster setup from a clean Ubuntu 22.04 / 24.04 machine.
#
# Run as a regular user (not root). Uses sudo internally where required.
#
# What this script does, in order:
#   1. Validates OS and non-root execution
#   2. Installs required tools: Incus, Terraform, Ansible, kubectl
#   3. Ensures the current user is in the 'incus' group (re-execs if needed)
#   4. Initialises Incus with minimal defaults (storage pool + bridge)
#   5. Configures UFW for Incus bridge networking (DHCP, DNS, NAT)
#   6. Provisions 3 VMs with Terraform (k3s-server-1, k3s-agent-1, k3s-agent-2)
#   7. Bootstraps k3s server via Ansible (installs k3s, writes ~/.kube/config)
#   8. Joins k3s agents via Ansible
#   9. Prints final cluster status
#
# Idempotency: safe to run multiple times. Each section checks current state
# before making changes. Running on an already-provisioned machine is a no-op.
#
# Requirements: Ubuntu 22.04 or 24.04 LTS, internet access.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
TERRAFORM_DIR="$REPO_ROOT/infra/terraform"
ANSIBLE_DIR="$REPO_ROOT/infra/ansible"

# ── Logging helpers ───────────────────────────────────────────────────────────
_step()  { echo; echo "------------------------------------------------------------"; echo "  STEP $*"; echo "------------------------------------------------------------"; }
_info()  { echo "       $*"; }
_ok()    { echo "  [OK] $*"; }
_fatal() { echo "[FAIL] $*" >&2; exit 1; }

# ── Step 0: Validate environment ─────────────────────────────────────────────
_step "0/8 — Validating environment"

[[ $EUID -ne 0 ]] || _fatal "Do not run as root. Run as a regular user; sudo is used internally."

source /etc/os-release 2>/dev/null || _fatal "Cannot read /etc/os-release — is this Linux?"
[[ "$ID" == "ubuntu" ]] || _fatal "This script targets Ubuntu. Detected: $ID $VERSION_ID"
_ok "Running on Ubuntu $VERSION_ID"

# ── Step 1: Install required tools ───────────────────────────────────────────
_step "1/8 — Installing required tools"

_info "Updating package index ..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  curl gnupg ca-certificates lsb-release apt-transport-https software-properties-common

# ── Incus (from zabbly/incus-stable repository) ──────────────────────────────
# Ubuntu ships an older Incus in universe; zabbly/incus-stable always provides
# the latest stable release maintained by the Incus upstream team.
if command -v incus &>/dev/null; then
  _ok "incus already installed — $(incus --version 2>/dev/null || echo 'unknown version')"
else
  _info "Installing Incus from zabbly/incus-stable ..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.zabbly.com/key.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/zabbly.gpg] \
https://pkgs.zabbly.com/incus/stable ${VERSION_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y incus
  _ok "incus installed"
fi

# ── Terraform (from HashiCorp apt repository) ────────────────────────────────
# The Terraform version constraint in versions.tf (>= 1.6.0) is satisfied by
# whatever HashiCorp ships as current stable. Version pinning for the provider
# itself (lxc/incus = 1.0.2) is enforced by Terraform at init time.
if command -v terraform &>/dev/null; then
  _ok "terraform already installed — $(terraform version -json 2>/dev/null | grep -oP '"terraform_version":"\K[^"]+' || echo 'unknown version')"
else
  _info "Installing Terraform from HashiCorp apt repo ..."
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y terraform
  _ok "terraform installed"
fi

# ── Ansible (from Ubuntu apt) ────────────────────────────────────────────────
# The playbooks use only ansible.builtin modules and require no collections.
# The Ubuntu apt package is sufficient and avoids pip dependency conflicts.
if command -v ansible-playbook &>/dev/null; then
  _ok "ansible already installed — $(ansible --version 2>/dev/null | head -1)"
else
  _info "Installing Ansible ..."
  sudo apt-get install -y ansible
  _ok "ansible installed"
fi

# ── kubectl (from Kubernetes apt repository) ─────────────────────────────────
# kubectl version should be within ±1 minor version of the k3s server.
# k3s stable channel currently installs v1.34.x; we install kubectl v1.33
# which is within the supported skew and is guaranteed available.
if command -v kubectl &>/dev/null; then
  _ok "kubectl already installed — $(kubectl version --client 2>/dev/null | head -1 || echo 'unknown version')"
else
  _info "Installing kubectl ..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y kubectl
  _ok "kubectl installed"
fi

# ── Step 2: Incus group membership ───────────────────────────────────────────
# The Incus socket (/run/incus/unix.socket) is owned by group 'incus'.
# Without group membership, 'incus' and 'terraform apply' (via the Incus
# provider) fail with a permission denied error.
#
# After adding the user to the group we re-exec the entire script under the
# new group context using 'sg'. The script re-runs from the top, skips all
# already-completed idempotent steps, and continues from here with the correct
# permissions — no logout/login required.
_step "2/8 — Incus group membership"

if id -nG "$USER" | tr ' ' '\n' | grep -q '^incus$'; then
  _ok "User '$USER' is already in the 'incus' group"
else
  _info "Adding '$USER' to the 'incus' group and re-executing ..."
  sudo usermod -aG incus "$USER"
  exec sg incus "$(realpath "${BASH_SOURCE[0]}")"
fi

# ── Step 3: Initialize Incus ─────────────────────────────────────────────────
# 'incus admin init --minimal' creates a default dir-backend storage pool and
# the default bridge incusbr0. Our Terraform config creates a separate bridge
# (k3sbr0) and storage is handled by the default pool — so minimal init is all
# we need. The check below makes this step idempotent.
_step "3/8 — Initializing Incus"

if incus storage list 2>/dev/null | grep -q 'default'; then
  _ok "Incus already initialized (default storage pool present)"
else
  _info "Running 'incus admin init --minimal' ..."
  incus admin init --minimal
  _ok "Incus initialized"
fi

# ── Step 4: Configure host networking (UFW) ───────────────────────────────────
# UFW on a fresh Ubuntu machine blocks:
#   - DHCP (port 67): VMs never get an IP from dnsmasq
#   - DNS  (port 53): VMs cannot resolve hostnames
#   - Forwarded packets: VMs cannot reach the internet
# setup-host.sh applies all three fixes idempotently and detects the outbound
# interface dynamically — no hardcoded interface names.
_step "4/8 — Configuring UFW for Incus bridge networking"

sudo "$REPO_ROOT/scripts/setup-host.sh"

# ── Step 5: Provision VMs with Terraform ─────────────────────────────────────
_step "5/8 — Provisioning VMs with Terraform"

_info "Running terraform init ..."
terraform -chdir="$TERRAFORM_DIR" init -upgrade -input=false

_info "Running terraform apply ..."
terraform -chdir="$TERRAFORM_DIR" apply -auto-approve -input=false

_ok "VMs provisioned"

# ── Step 6: Bootstrap k3s server ─────────────────────────────────────────────
# Playbook 01:
#   - Installs curl + ca-certificates in the server VM
#   - Installs k3s server with: --disable traefik --tls-san <vm-ip>
#   - Waits for k3s service active, API responsive, node Ready
#   - Writes ~/.kube/config with the correct server IP
_step "6/8 — Bootstrapping k3s server"

ansible-playbook "$ANSIBLE_DIR/playbooks/01-install-k3s-server.yaml"

# ── Step 7: Join k3s agents ───────────────────────────────────────────────────
# Playbook 02:
#   - Installs curl + ca-certificates in each agent VM
#   - Joins both agents to the server using the node token
#   - Token is passed via stdin (never appears in process argv)
#   - Waits for all nodes Ready
_step "7/8 — Joining k3s agents"

ansible-playbook "$ANSIBLE_DIR/playbooks/02-join-k3s-agents.yaml"

# ── Step 8: Validate ─────────────────────────────────────────────────────────
_step "8/8 — Cluster validation"

kubectl get nodes -o wide

echo
_ok "Bootstrap complete. The k3s cluster is ready."
_ok "Run 'kubectl get nodes' at any time to check cluster state."
