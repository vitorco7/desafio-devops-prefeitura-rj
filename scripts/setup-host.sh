#!/usr/bin/env bash
# setup-host.sh — Idempotent host preparation for Incus k3s cluster
#
# What this script does:
#   1. Detects the host's default outbound interface dynamically
#   2. Ensures UFW forward policy is ACCEPT
#   3. Ensures a MASQUERADE (NAT) rule exists in /etc/ufw/before.rules for k3sbr0
#   4. Adds UFW rules to allow DHCP, DNS, and general forwarding on k3sbr0
#   5. Reloads UFW
#
# Idempotency: every section checks current state before making changes.
# Safe to run multiple times on the same machine or on a fresh machine.
#
# Usage:
#   sudo ./scripts/setup-host.sh
#
# Requirements: ufw, awk, ip

set -euo pipefail

# ── Privilege check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

BRIDGE="k3sbr0"
BRIDGE_CIDR="10.220.31.0/24"
UFW_BEFORE_RULES="/etc/ufw/before.rules"
UFW_DEFAULT="/etc/default/ufw"

# ── Ensure UFW is installed ───────────────────────────────────────────────────
if ! command -v ufw &>/dev/null; then
  echo "UFW not found — installing..."
  apt-get update -qq
  apt-get install -y ufw
  # Enable UFW non-interactively without blocking existing connections
  ufw --force enable
  echo "UFW installed and enabled."
fi

# ── Step 1: Detect default outbound interface ─────────────────────────────────
# `ip route get 8.8.8.8` prints the route used to reach the internet.
# We extract the interface name from that output — works on any Linux host
# regardless of whether the NIC is wlp0s20f3, eth0, ens3, wlan0, etc.
OUTBOUND_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ { for(i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }')

if [[ -z "$OUTBOUND_IF" ]]; then
  echo "ERROR: Could not detect default outbound interface. Is networking up?" >&2
  exit 1
fi

echo "Detected outbound interface: $OUTBOUND_IF"
echo "Bridge: $BRIDGE ($BRIDGE_CIDR)"
echo ""

# ── Step 2: Set UFW forward policy to ACCEPT ─────────────────────────────────
# UFW's default is DROP for forwarded packets, which blocks VM-to-internet traffic
# even after NAT is configured. We change this to ACCEPT.
if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "$UFW_DEFAULT"; then
  echo "[1/4] Setting DEFAULT_FORWARD_POLICY=ACCEPT in $UFW_DEFAULT ..."
  sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$UFW_DEFAULT"
else
  echo "[1/4] DEFAULT_FORWARD_POLICY already ACCEPT — skipping."
fi

# ── Step 3: Add NAT MASQUERADE rule to /etc/ufw/before.rules ─────────────────
# UFW processes /etc/ufw/before.rules before its own rules. We inject a *nat
# table block at the very top so that traffic from the bridge subnet is
# masqueraded (source-NATed) when leaving via the outbound interface.
#
# We check for the exact MASQUERADE rule to stay idempotent — inserting twice
# would create duplicate rules and confuse nftables.
NAT_MARKER="-A POSTROUTING -s ${BRIDGE_CIDR} -o ${OUTBOUND_IF} -j MASQUERADE"

if grep -qF "$NAT_MARKER" "$UFW_BEFORE_RULES"; then
  echo "[2/4] MASQUERADE rule already present in $UFW_BEFORE_RULES — skipping."
else
  echo "[2/4] Inserting MASQUERADE rule into $UFW_BEFORE_RULES ..."
  # Prepend the *nat block before the first existing content
  # We use a temp file to avoid in-place issues with complex here-docs
  TMP=$(mktemp)
  {
    echo "# NAT for Incus ${BRIDGE} VMs — added by setup-host.sh"
    echo "*nat"
    echo ":POSTROUTING ACCEPT [0:0]"
    echo "${NAT_MARKER}"
    echo "COMMIT"
    echo ""
    cat "$UFW_BEFORE_RULES"
  } > "$TMP"
  mv "$TMP" "$UFW_BEFORE_RULES"
fi

# ── Step 4: Add UFW allow rules on the bridge interface ──────────────────────
# ufw allow rules are idempotent by default: running them twice results in
# "Skipping adding existing rule" — no harm, no duplicate entries.

echo "[3/4] Ensuring UFW rules for DHCP, DNS, and forwarding on ${BRIDGE} ..."

_ufw_bridge_rules() {
  local br="$1"
  # DHCP: VMs request IP addresses via UDP broadcast to port 67 on the bridge.
  # Without this, dnsmasq never hears the DHCPDISCOVER and VMs get no IP.
  ufw allow in on "${br}" to any port 67 proto udp \
    comment "Incus ${br} DHCP" > /dev/null

  # DNS: VMs forward DNS queries to dnsmasq at the bridge gateway.
  # Without this, systemd-resolved inside the VM hangs on every hostname lookup.
  ufw allow in on "${br}" to any port 53 \
    comment "Incus ${br} DNS" > /dev/null

  # General forwarding: allow all traffic in/out of the bridge.
  ufw allow in on "${br}" \
    comment "Incus ${br} forward in" > /dev/null
  ufw allow out on "${br}" \
    comment "Incus ${br} forward out" > /dev/null
}

# Apply rules to the k3s bridge (cluster VMs)
_ufw_bridge_rules "${BRIDGE}"

# Apply the same rules to the default Incus bridge (incusbr0).
# This is used by non-k3s VMs such as the fresh-install test VM.
# Without these rules, VMs on incusbr0 cannot get an IP via DHCP
# or reach the internet, even though DEFAULT_FORWARD_POLICY=ACCEPT.
if ip link show incusbr0 &>/dev/null; then
  _ufw_bridge_rules "incusbr0"
fi

# ── Step 5: Reload UFW ───────────────────────────────────────────────────────
echo "[4/4] Reloading UFW ..."
ufw reload > /dev/null

echo ""
echo "Host setup complete. Summary:"
echo "  Outbound interface : $OUTBOUND_IF"
echo "  Forward policy     : ACCEPT"
echo "  MASQUERADE rule    : $BRIDGE_CIDR → $OUTBOUND_IF"
echo "  UFW rules added    : DHCP (udp/67), DNS (53), forward in/out on $BRIDGE"
echo ""
echo "You can now run:"
echo "  cd infra/terraform && terraform init && terraform apply"
echo "  ansible-playbook infra/ansible/playbooks/01-install-k3s-server.yaml"
echo "  ansible-playbook infra/ansible/playbooks/02-join-k3s-agents.yaml"
