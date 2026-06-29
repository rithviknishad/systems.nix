#
# k3s — single-node Kubernetes (cluster-ready).
#
# Runs avocado as a k3s *server* with embedded etcd (clusterInit), so more
# servers/agents can join later for HA. Joining nodes use the shared token in
# secrets/avocado.yaml under k3s/token (any long random string; generate with
# `openssl rand -hex 32`). Bundled add-ons (Traefik ingress, local-path
# storage, ServiceLB) are left on for an easy first workload.
#
# Remote access (kubectl/Lens from the Mac): the API cert is issued for the
# tailnet name via tls-san, so copy /etc/rancher/k3s/k3s.yaml off the box and
# point its server URL at https://avocado:6443.
#
{
  pkgs,
  config,
  ...
}:
{
  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    tokenFile = config.sops.secrets."k3s/token".path;
    extraFlags = [
      "--tls-san=avocado"
      "--tls-san=avocado.local"
      "--write-kubeconfig-mode=0640"
    ];
  };

  sops.secrets."k3s/token" = { };

  # Cluster tooling on the box.
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];

  # k3s API + node ports. tailscale0 is already a trusted interface, so this
  # is mainly for LAN/other-node access. etcd ports (2379/2380) only matter
  # once you add more servers.
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
