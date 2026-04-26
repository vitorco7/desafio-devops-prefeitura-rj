#!/usr/bin/env bash
# teardown-vm.sh -- HOST script. Stops and deletes the test VM.
#
# Usage: bash scripts/fresh-install-testing/teardown-vm.sh

set -euo pipefail

VM_NAME="fresh-ubuntu"

if ! incus info "$VM_NAME" &>/dev/null; then
  echo "VM '$VM_NAME' does not exist. Nothing to do."
  exit 0
fi

read -rp "Destroy VM '$VM_NAME' and delete all its data? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "Stopping VM '$VM_NAME'..."
incus stop "$VM_NAME" --force 2>/dev/null || true

echo "Deleting VM '$VM_NAME'..."
incus delete "$VM_NAME"

echo "[OK] VM '$VM_NAME' destroyed."
