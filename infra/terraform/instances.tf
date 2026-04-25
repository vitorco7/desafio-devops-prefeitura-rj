resource "incus_instance" "nodes" {
  for_each = local.cluster_nodes

  name     = each.value.name
  type     = local.node_defaults.type
  image    = local.node_defaults.image
  running  = true
  profiles = [incus_profile.k3s_vm.name]

  config = {
    "boot.autostart" = "true"
    "limits.cpu"     = tostring(local.node_defaults.cpu)
    "limits.memory"  = "${local.node_defaults.memory_mb}MiB"
    "user.role"      = each.value.role
  }

}
