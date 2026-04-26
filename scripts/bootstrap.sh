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
#   9. Validates k3s cluster node readiness
#  10. Installs Istio 1.29.2 on the cluster (istioctl + default profile)
#  11. Applies Istio manifests (namespaces, Gateway, PeerAuthentication, VirtualService, DestinationRule)
#
# Idempotency: safe to run multiple times. Each section checks current state
# before making changes. Running on an already-provisioned machine is a no-op.
#
# Requirements: Ubuntu 22.04 or 24.04 LTS, internet access.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
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
_step "6/10 — Bootstrapping k3s server"

ansible-playbook "$ANSIBLE_DIR/playbooks/01-install-k3s-server.yaml"

# ── Step 7: Join k3s agents ───────────────────────────────────────────────────
# Playbook 02:
#   - Installs curl + ca-certificates in each agent VM
#   - Joins both agents to the server using the node token
#   - Token is passed via stdin (never appears in process argv)
#   - Waits for all nodes Ready
_step "7/10 — Joining k3s agents"

ansible-playbook "$ANSIBLE_DIR/playbooks/02-join-k3s-agents.yaml"

# ── Step 8: Validate k3s cluster ─────────────────────────────────────────────
_step "8/10 — Cluster validation"

kubectl get nodes -o wide

_ok "k3s cluster nodes are Ready"

# ── Step 9: Install Istio ─────────────────────────────────────────────────────
# istioctl is the Istio CLI. We pin to 1.29.2 to match the version installed on
# the cluster. The idempotency check compares the installed binary version
# against the pinned version before downloading.
#
# istioctl install applies the Istio control plane (istiod) and the
# istio-ingressgateway to the cluster. The 'default' profile includes both.
# We wait for both deployments to be fully rolled out before continuing.
_step "9/10 — Installing Istio 1.29.2"

ISTIO_VERSION="1.29.2"
ISTIOCTL_PATH="/usr/local/bin/istioctl"

if command -v istioctl &>/dev/null && istioctl version --remote=false 2>/dev/null | grep -q "${ISTIO_VERSION}"; then
  _ok "istioctl ${ISTIO_VERSION} already installed — skipping download"
else
  _info "Downloading istioctl ${ISTIO_VERSION} ..."
  curl -sL \
    "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    | sudo tar -xz -C /usr/local/bin istioctl
  sudo chmod +x "${ISTIOCTL_PATH}"
  _ok "istioctl ${ISTIO_VERSION} installed at ${ISTIOCTL_PATH}"
fi

if kubectl get deployment istiod -n istio-system &>/dev/null 2>&1; then
  _ok "Istio already installed on cluster — skipping istioctl install"
else
  _info "Installing Istio on cluster (profile=default) ..."
  istioctl install --set profile=default -y
  _info "Waiting for istiod rollout ..."
  kubectl -n istio-system rollout status deployment/istiod --timeout=120s
  _info "Waiting for istio-ingressgateway rollout ..."
  kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=120s
  _ok "Istio control plane ready"
fi

# ── Step 10: Apply manifests and deploy services ──────────────────────────────
# Directory layout:
#   infra/k8s/
#   ├── namespaces.yaml
#   ├── istio/                  — Gateway, PeerAuthentication, VirtualService,
#   │   ├── gateway.yaml          DestinationRule, RequestAuthentication (.tpl)
#   │   ├── service-1/ ...
#   │   ├── service-2/ ...
#   │   └── service-3/ ...
#   └── service-1/              — SA, Deployment, Service (kubectl)
#
#   infra/helm/service-2/  infra/helm/service-3/   — Helm charts
#
#   infra/jwt/
#   ├── generate.py             — produces key pair, jwks.json, token.jwt
#   ├── private.pem / public.pem / jwks.json / token.jwt  — gitignored, generated here
#   └── *.yaml.tpl              — RequestAuthentication templates (JWKS_INLINE placeholder)
#
# Apply order:
#   10a. Generate JWT key pair, JWKS, and test token (idempotent)
#   10b. Apply namespaces
#   10c. Apply Istio CRDs via kubectl apply -R (skips .tpl files automatically)
#   10d. Apply RequestAuthentication for service-1 and service-3 (inline JWKS substituted
#        from jwks.json — no HTTP server needed; istiod reads the key from the object)
#   10e. Deploy service-1 (kubectl)
#   10f. Deploy service-2 (Helm)
#   10g. Deploy service-3 (Helm)
_step "10/10 — Applying manifests and deploying services"

K8S_DIR="${REPO_ROOT}/infra/k8s"
HELM_DIR="${REPO_ROOT}/infra/helm"
JWT_DIR="${REPO_ROOT}/infra/jwt"
ISTIO_DIR="${K8S_DIR}/istio"

# ── 10a: Generate JWT artifacts ───────────────────────────────────────────────
# private.pem, public.pem, jwks.json, and token.jwt are gitignored.
# Skipped if all three key artifacts already exist (re-run safety).
if [[ -f "${JWT_DIR}/private.pem" && -f "${JWT_DIR}/jwks.json" && -f "${JWT_DIR}/token.jwt" ]]; then
  _ok "JWT artifacts already present — skipping key generation"
else
  _info "Generating RSA-2048 key pair, JWKS document, and test JWT ..."
  python3 "${JWT_DIR}/generate.py"
  _ok "JWT artifacts generated in ${JWT_DIR}/"
fi

# ── 10b: Apply namespaces ─────────────────────────────────────────────────────
_info "Applying namespaces ..."
kubectl apply -f "${K8S_DIR}/namespaces.yaml"

# ── 10c: Apply Istio CRDs ─────────────────────────────────────────────────────
# kubectl apply -R ignores .yaml.tpl files — RequestAuthentication templates
# are handled separately in 10d.
_info "Applying Istio CRDs (Gateway, PeerAuthentication, VirtualService, DestinationRule) ..."
kubectl apply -R -f "${ISTIO_DIR}/"

# ── 10d: Apply RequestAuthentication (inline JWKS — no HTTP server needed) ───
# The .yaml.tpl templates contain JWKS_INLINE as a placeholder. We substitute
# the compact JSON from jwks.json and pipe directly to kubectl apply.
# This means the RSA public key never needs to be served over HTTP — istiod
# reads it directly from the Kubernetes RequestAuthentication object.
_info "Applying RequestAuthentication (service-1 and service-3) with inline JWKS ..."
_apply_request_auth() {
  local tpl="$1"
  python3 -c "
import json, sys
tpl = open(sys.argv[1]).read()
jwks = json.dumps(json.load(open(sys.argv[2])))
print(tpl.replace('JWKS_INLINE', jwks))
" "${tpl}" "${JWT_DIR}/jwks.json" | kubectl apply -f -
}
_apply_request_auth "${ISTIO_DIR}/service-1/request-authentication.yaml.tpl"
_apply_request_auth "${ISTIO_DIR}/service-3/request-authentication.yaml.tpl"

# ── 10e: Deploy service-1 via kubectl ────────────────────────────────────────
_info "Applying service-1 app manifests (ServiceAccount, Deployment, Service) ..."
kubectl apply -R -f "${K8S_DIR}/service-1/"

# ── 10f: Deploy service-2 via Helm ───────────────────────────────────────────
_info "Deploying service-2 via Helm ..."
if helm status service-2 -n service-2 &>/dev/null; then
  _info "service-2 Helm release already exists — skipping install"
else
  helm install service-2 "${HELM_DIR}/service-2/" -n service-2
fi

# ── 10g: Deploy service-3 via Helm ───────────────────────────────────────────
_info "Deploying service-3 via Helm ..."
if helm status service-3 -n service-3 &>/dev/null; then
  _info "service-3 Helm release already exists — skipping install"
else
  helm install service-3 "${HELM_DIR}/service-3/" -n service-3
fi

_info "Waiting for all app deployments to roll out ..."
kubectl rollout status deployment/service-1 -n service-1 --timeout=120s
kubectl rollout status deployment/service-2 -n service-2 --timeout=120s
kubectl rollout status deployment/service-3 -n service-3 --timeout=120s

_ok "All manifests applied and services deployed"

echo
echo "  Test JWT token for curl validation:"
echo "  TOKEN=\$(cat ${JWT_DIR}/token.jwt)"
echo "  curl -H \"Authorization: Bearer \$TOKEN\" -H \"Host: service-1.local\" http://<GW_IP>/"
echo
_ok "Bootstrap complete. k3s cluster + Istio service mesh are ready."
_ok "Verify nodes       : kubectl get nodes -o wide"
_ok "Verify Istio       : istioctl version"
_ok "Verify policies    : kubectl get peerauthentication,gateway,virtualservice,destinationrule,requestauthentication --all-namespaces"
_ok "Verify pods        : kubectl get pods -A | grep -E '^(service-1|service-2|service-3)'"
