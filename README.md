# This is a README file for the project

Escolha de stacks:

Opções: 

| Ferramenta                                                                        | Backend               |
| --------------------------------------------------------------------------------- | --------------------- |
| [Incus](https://linuxcontainers.org/incus/)                                       | LXC/KVM               |
| [Multipass](https://multipass.run/)                                               | HyperKit/QEMU/Hyper-V |
| [Vagrant](https://www.vagrantup.com/) + [VirtualBox](https://www.virtualbox.org/) | VirtualBox            |
| [Vagrant](https://www.vagrantup.com/) + [libvirt](https://libvirt.org/)           | KVM/QEMU              |

O vagrant é redundante quando utiliza-se Terraform, pois o Terraform já tem suporte nativo para os provedores de virtualização. O vagrant é mais utilizado para desenvolvimento local, enquanto o Terraform é mais adequado para provisionamento em larga escala e automação de infraestrutura. Isso já elimina o Vagrant + VirtualBox e o Vagrant + libvirt da lista de opções.

Além disso, por se tratar de um hypervisor tipo 2, o VirtualBox adiciona mais overhead no projeto, sem falar que o Terraform não tem provider nativo para o VirtualBox. enquanto o libvirt adiciona mais complexidade por necessitar de mais dependências.

Enquanto isso, o Multipass não possui suporte nativo para o Terraform, o que pode dificultar a automação do provisionamento de infraestrutura.

Visto isso, a melhor opção para o projeto é o Incus, pois ele é um hypervisor tipo 1, o que significa que ele tem menos overhead e é mais eficiente do que os hypervisors tipo 2. Além disso, o Incus tem suporte nativo para o Terraform, o que facilita a automação do provisionamento de infraestrutura.

Portanto, a escolha do Incus como motor de virtualização para o projeto é a melhor opção, pois ele oferece uma solução mais eficiente tanto a nível de desempenho quanto a nível de automação, em comparação com as outras opções disponíveis.

## Stack escolhida:
Terraform, Ansible, Incus


### Considerações a respeito do Incus VM vs LXC:
O Istio opera diretamente no nível de rede do kernel para interceptar e controlar todo o tráfego dos pods — ele depende de iptables, do capability NET_ADMIN e de um init container privilegiado (istio-init) que reconfigura as regras de rede antes de cada pod subir. Em um container LXC, o kernel é compartilhado com o host, o que significa que qualquer manipulação de iptables feita pelo Istio afeta as regras de rede da máquina host inteira, criando riscos de instabilidade e segurança. Além disso, capacidades privilegiadas como NET_ADMIN são restritas por padrão no LXC, e o istio-init container privilegiado é bloqueado — o que impede o Istio de funcionar corretamente sem configurações manuais arriscadas e não recomendadas para ambientes reproduzíveis.

A Incus VM, por sua vez, provisiona cada nó com seu próprio kernel isolado via KVM/QEMU, eliminando todos esses problemas. Dentro de uma VM, o iptables manipulado pelo Istio afeta apenas aquele nó sem nenhum impacto no host ou nos demais nós do cluster, o containerd do k3s sobe sem restrições de nesting, e todas as capabilities privilegiadas operam de forma segura dentro do ambiente virtualizado. O custo adicional de memória (~512 MB por nó em comparação com ~50 MB de um container LXC) é justificado pelo isolamento de kernel necessário para garantir o funcionamento estável e correto do Istio — tornando a VM a escolha tecnicamente correta para este projeto.

