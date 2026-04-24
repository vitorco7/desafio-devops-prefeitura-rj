locals {
  # Base settings shared by every cluster node.
  node_defaults = {
    image     = "images:ubuntu/24.04"
    type      = "virtual-machine"
    cpu       = 2
    memory_mb = 4096
    disk_gb   = 30
  }

  # Explicit 3-node topology required by the challenge:
  # 1 control-plane server + 2 workers.
  cluster_nodes = {
    server = {
      name = "k3s-server-1"
      role = "server"
    }

    agent1 = {
      name = "k3s-agent-1"
      role = "agent"
    }

    agent2 = {
      name = "k3s-agent-2"
      role = "agent"
    }
  }
}
