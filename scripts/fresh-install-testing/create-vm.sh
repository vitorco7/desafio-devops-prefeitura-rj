#!/usr/bin/env bash
# create-vm.sh -- HOST script. Creates a fresh Ubuntu 24.04 VM and prepares it
# for reproducibility testing.
#
# What this script does:
#   1. Creates the VM (nested KVM, 20 GiB RAM, 40 GiB disk)
#   2. Waits for cloud-init to finish
#   3. Creates a non-root user 'tester' with passwordless sudo
#   4. Copies run-test.sh into the VM at /home/tester/run-test.sh
#
# After this script, shell into the VM and run the test:
#   incus exec fresh-ubuntu -- su -l tester
#   bash run-test.sh
#
# Requirements: Incus installed and initialized on the host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
VM_NAME="fresh-ubuntu"
VM_IMAGE="images:ubuntu/24.04"
VM_CPU=4
VM_RAM="20GiB"
VM_DISK="40GiB"
TEST_USER="tester"

# -- Idempotency check ---------------------------------------------------------
if incus info "$VM_NAME" &>/dev/null; then
  STATE=$(incus list "$VM_NAME" --format csv -c s)
  echo "[OK] VM '$VM_NAME' already exists (state: $STATE)."
  echo "     To start fresh: bash scripts/fresh-install-testing/teardown-vm.sh"
  exit 0
fi

# -- Create VM -----------------------------------------------------------------
echo "Creating VM '$VM_NAME' (${VM_CPU} vCPU, ${VM_RAM} RAM, ${VM_DISK} disk)..."
incus launch "$VM_IMAGE" "$VM_NAME" \
  --vm \
  --config limits.cpu="$VM_CPU" \
  --config limits.memory="$VM_RAM" \
  --device root,size="$VM_DISK"

# -- Wait for cloud-init -------------------------------------------------------
echo "Waiting for VM to finish booting (cloud-init)..."
for i in $(seq 1 60); do
  if incus exec "$VM_NAME" -- test -f /var/lib/cloud/instance/boot-finished 2>/dev/null; then
    break
  fi
  printf "."
  sleep 5
done
echo

# -- Install git --------------------------------------------------------------
echo "Installing git..."
incus exec "$VM_NAME" -- apt-get update -qq
incus exec "$VM_NAME" -- apt-get install -y --no-install-recommends git

# -- Create non-root user with passwordless sudo -------------------------------
echo "Creating user '$TEST_USER' with passwordless sudo..."
incus exec "$VM_NAME" -- bash -c "
  useradd -m -s /bin/bash '$TEST_USER'
  echo '${TEST_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${TEST_USER}
  chmod 440 /etc/sudoers.d/${TEST_USER}
  # Add to incus and incus-admin groups so 'incus admin init' works without sudo.
  # On Incus 6.x (zabbly), incus-admin owns /var/lib/incus/unix.socket (admin socket).
  # The bootstrap.sh only checks for 'incus' group, but a fresh useradd has neither.
  usermod -aG incus,incus-admin '${TEST_USER}'
"

# Incus 6.x assigns each non-root user their own project (user-<uid>) by default.
# Terraform provisions VMs in the 'default' project (admin context).
# Without this, 'incus exec k3s-server-1' as tester fails with "Instance not found"
# because it looks in 'user-1001' instead of 'default'.
echo "Configuring Incus default project for '$TEST_USER'..."
incus exec "$VM_NAME" -- su -l "$TEST_USER" -c "incus project switch default"

# -- Inject run-test.sh into the VM -------------------------------------------
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
