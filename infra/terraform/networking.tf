resource "incus_network" "k3s_bridge" {
  name = "k3sbr0"
  type = "bridge"

  config = {
    "ipv4.address" = "10.220.31.1/24"
    "ipv4.dhcp"    = "true"
    "ipv4.nat"     = "true"
    "ipv6.address" = "none"
  }
}

resource "incus_profile" "k3s_network" {
  name        = "k3s-network"
  description = "Project-specific NIC profile for k3s nodes."

  # Use eth0 so this profile overrides any conflicting default-profile NIC
  # and guarantees predictable VM-to-bridge attachment.
  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.k3s_bridge.name
    }
  }
}
