#
# k3s server — the control plane (avocado).
#
# Runs as a k3s *server* with embedded etcd (clusterInit) and is the only
# server: g8way and headless join as agents (modules/k3s-agent.nix). Shared
# settings (token, tailnet node-ip, flannel over tailscale0) live in
# ./k3s-common.nix. Bundled add-ons (Traefik ingress, local-path storage,
# ServiceLB) are left on.
#
# Remote access (kubectl/Lens from the Mac): the API cert is issued for the
# tailnet name via tls-san, so copy /etc/rancher/k3s/k3s.yaml off the box and
# point its server URL at https://avocado:6443.
#
{ pkgs, ... }:
{
  imports = [ ./k3s-common.nix ];

  services.k3s = {
    role = "server";
    clusterInit = true;
    extraFlags = [
      "--tls-san=avocado"
      "--tls-san=avocado.local"
      "--write-kubeconfig-mode=0640"
    ];
  };

  # Cluster tooling on the box.
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];

  # k3s API + node ports. tailscale0 is already a trusted interface (and all
  # cluster traffic now rides it, see ./k3s-common.nix), so this is mainly
  # for LAN kubectl access. etcd ports (2379/2380) only matter once you add
  # more servers.
  networking.firewall.allowedTCPPorts = [
    6443 # kube API
    2379 # etcd client
    2380 # etcd peer
    10250 # kubelet
  ];
  networking.firewall.allowedUDPPorts = [
    8472 # flannel vxlan
  ];
}
