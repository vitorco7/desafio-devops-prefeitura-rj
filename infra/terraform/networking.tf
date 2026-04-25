resource "incus_network" "k3s_bridge" {
  name = "k3sbr0"
  type = "bridge"

  config = {
    "ipv4.address"  = "10.220.31.1/24"
    "ipv4.dhcp"     = "true"
    "ipv4.nat"      = "true"
    "ipv4.firewall" = "false"
    "ipv6.address"  = "none"
  }
}

# Single self-contained profile that fully defines a k3s node:
#   - root disk  → "default" dir storage pool (pre-existing host resource,
#                   created by `incus admin init --minimal` in bootstrap.sh;
#                   not Terraform-managed — cannot be created or destroyed here)
#   - eth0 NIC   → k3sbr0 bridge
#
# Instances reference only this profile, so the entire VM configuration is
# visible in version control with no implicit dependency on the Incus-managed
# "default" profile.
resource "incus_profile" "k3s_vm" {
  name        = "k3s-vm"
  description = "Complete VM profile: root disk on default pool + NIC on k3sbr0."

  depends_on = [incus_network.k3s_bridge]

  device {
    name = "root"
    type = "disk"

    properties = {
      path = "/"
      pool = "default"
    }
  }

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.k3s_bridge.name
    }
  }
}


