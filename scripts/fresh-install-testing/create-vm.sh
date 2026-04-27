#!/usr/bin/env bash
# create-vm.sh -- HOST script. Creates a fresh Ubuntu 24.04 VM and prepares it
# for reproducibility testing.
#
# Self-contained: installs and initializes Incus if not already present.
# Safe to run on a clean Ubuntu 22.04 / 24.04 machine with no prior setup.
#
# What this script does:
#   1. Installs Incus (from zabbly/incus-stable) if missing
#   2. Ensures current user is in incus / incus-admin groups (re-execs if needed)
#   3. Initializes Incus if not already initialized
#   4. Switches CLI project to 'default'
#   5. Creates the VM (nested KVM, 20 GiB RAM, 30 GiB disk)
#   6. Waits for cloud-init to finish
#   7. Creates a non-root user 'tester' with passwordless sudo
#   8. Copies run-test.sh into the VM at /home/tester/run-test.sh
#
# After this script, shell into the VM and run the test:
#   incus exec fresh-ubuntu -- su -l tester
#   bash run-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
VM_NAME="fresh-ubuntu"
VM_IMAGE="images:ubuntu/24.04"
VM_CPU=4
VM_RAM="20GiB"
VM_DISK="30GiB"
TEST_USER="tester"

[[ $EUID -ne 0 ]] || { echo "[FAIL] Do not run as root. Run as a regular user." >&2; exit 1; }

source /etc/os-release 2>/dev/null || { echo "[FAIL] Cannot read /etc/os-release" >&2; exit 1; }

# ── Step 1: Install Incus if missing ─────────────────────────────────────────
if command -v incus &>/dev/null; then
  echo "[OK] incus already installed — $(incus --version 2>/dev/null || echo 'unknown version')"
else
  echo "     Installing Incus from zabbly/incus-stable ..."
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends curl gnupg ca-certificates
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.zabbly.com/key.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/zabbly.gpg] \
https://pkgs.zabbly.com/incus/stable ${VERSION_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y incus
  echo "[OK] incus installed"
fi

# ── Step 2: Group membership + re-exec ───────────────────────────────────────
# incus       — owns /run/incus/unix.socket (user CLI socket)
# incus-admin — owns /var/lib/incus/unix.socket (admin socket, required for
#               'incus admin init' and for incus exec to reach the 'default' project)
_needs_reexec=0
if ! id -nG "$USER" | tr ' ' '\n' | grep -q '^incus$'; then
  echo "     Adding '$USER' to the 'incus' group ..."
  sudo usermod -aG incus "$USER"
  _needs_reexec=1
fi
if getent group incus-admin &>/dev/null \
    && ! id -nG "$USER" | tr ' ' '\n' | grep -q '^incus-admin$'; then
  echo "     Adding '$USER' to the 'incus-admin' group ..."
  sudo usermod -aG incus-admin "$USER"
  _needs_reexec=1
fi
if [[ $_needs_reexec -eq 0 ]] && getent group incus-admin &>/dev/null; then
  _incus_admin_gid=$(getent group incus-admin | cut -d: -f3)
  if ! id -G | tr ' ' '\n' | grep -qx "$_incus_admin_gid"; then
    echo "     incus-admin registered but not active in session — re-executing ..."
    _needs_reexec=1
  fi
fi
if [[ $_needs_reexec -eq 1 ]]; then
  echo "     Re-executing under incus-admin group context ..."
  _script="$(realpath "${BASH_SOURCE[0]}")"
  exec sg incus-admin "bash \"$_script\""
fi
echo "[OK] User '$USER' has incus and incus-admin active in this session"

export INCUS_SOCKET="/var/lib/incus/unix.socket"

# ── Step 3: Initialize Incus if needed ───────────────────────────────────────
if sudo incus storage list --format csv 2>/dev/null | grep -q '^default,'; then
  echo "[OK] Incus already initialized"
else
  echo "     Running 'incus admin init --minimal' ..."
  sudo incus admin init --minimal
  echo "[OK] Incus initialized"
fi

incus project switch default
echo "[OK] Incus CLI project set to 'default'"

# ── Step 4: Idempotency check ─────────────────────────────────────────────────
if incus info "$VM_NAME" &>/dev/null; then
  STATE=$(incus list "$VM_NAME" --format csv -c s)
  echo "[OK] VM '$VM_NAME' already exists (state: $STATE)."
  echo "     To start fresh: bash scripts/fresh-install-testing/teardown-vm.sh"
  exit 0
fi

# ── Step 5: Create VM ─────────────────────────────────────────────────────────
echo "Creating VM '$VM_NAME' (${VM_CPU} vCPU, ${VM_RAM} RAM, ${VM_DISK} disk)..."
incus launch "$VM_IMAGE" "$VM_NAME" \
  --vm \
  --config limits.cpu="$VM_CPU" \
  --config limits.memory="$VM_RAM" \
  --device root,size="$VM_DISK"

# ── Step 6: Wait for cloud-init ───────────────────────────────────────────────
echo "Waiting for VM to finish booting (cloud-init)..."
for i in $(seq 1 60); do
  if incus exec "$VM_NAME" -- test -f /var/lib/cloud/instance/boot-finished 2>/dev/null; then
    break
  fi
  printf "."
  sleep 5
done
echo

# ── Step 7: Install git ───────────────────────────────────────────────────────
echo "Installing git..."
incus exec "$VM_NAME" -- apt-get update -qq
incus exec "$VM_NAME" -- apt-get install -y --no-install-recommends git

# ── Step 8: Create non-root user with passwordless sudo ───────────────────────
# NOTE: We do NOT add tester to incus/incus-admin groups here — Incus is not
# installed yet inside this VM. bootstrap.sh Step 2 handles that after Incus
# is installed (installs groups, adds user, re-execs with 'sg incus-admin').
echo "Creating user '$TEST_USER' with passwordless sudo..."
incus exec "$VM_NAME" -- bash -c "
  useradd -m -s /bin/bash '$TEST_USER'
  echo '${TEST_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${TEST_USER}
  chmod 440 /etc/sudoers.d/${TEST_USER}
"

# ── Step 9: Inject run-test.sh into the VM ────────────────────────────────────
echo "Copying run-test.sh into VM at /home/${TEST_USER}/run-test.sh..."
incus file push "${SCRIPT_DIR}/run-test.sh" "${VM_NAME}/home/${TEST_USER}/run-test.sh"
incus exec "$VM_NAME" -- chown "${TEST_USER}:${TEST_USER}" "/home/${TEST_USER}/run-test.sh"
incus exec "$VM_NAME" -- chmod +x "/home/${TEST_USER}/run-test.sh"

echo ""
echo "[OK] VM '$VM_NAME' is ready."
echo ""
echo "Next steps:"
echo "  1. Shell into the VM:"
echo "       incus exec fresh-ubuntu -- su -l tester"
echo "  2. Inside the VM, run the test:"
echo "       bash run-test.sh"
