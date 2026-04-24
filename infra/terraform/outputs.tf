output "nodes" {
  description = "Cluster nodes indexed by topology key (server, agent1, agent2)."
  value = {
    for key, node in incus_instance.nodes : key => {
      name = node.name
      role = local.cluster_nodes[key].role
      ipv4 = node.ipv4_address
      ipv6 = node.ipv6_address
    }
  }
}

output "k3s_server" {
  description = "Primary k3s server node details."
  value = {
    name = incus_instance.nodes["server"].name
    ipv4 = incus_instance.nodes["server"].ipv4_address
    ipv6 = incus_instance.nodes["server"].ipv6_address
  }
}

output "k3s_agents" {
  description = "k3s agent nodes details."
  value = {
    for key, node in incus_instance.nodes : key => {
      name = node.name
      ipv4 = node.ipv4_address
      ipv6 = node.ipv6_address
    } if local.cluster_nodes[key].role == "agent"
  }
}
