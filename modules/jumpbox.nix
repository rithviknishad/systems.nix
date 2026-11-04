#
# Jumpbox: tools to watch and poke the k3s cluster (control plane on
# avocado) from another machine, plus that cluster's admin kubeconfig.
#
# Host-agnostic, but the importing host's secrets/<hostname>.yaml must carry a
# `kubeconfig` key (avocado's admin kubeconfig with `server:
# https://avocado:6443` — the API cert has --tls-san=avocado, and MagicDNS
# resolves `avocado` on the tailnet). Never import this on avocado: k3s.nix
# already installs kubectl/helm/k9s there and writes its own kubeconfig.
#
{ config, pkgs, ... }:
{
  # git, nmap, htop, tmux come from base.nix.
  environment.systemPackages = with pkgs; [
    # cluster
    kubectl
    kubectx # kubectx + kubens
    k9s
    stern # multi-pod log tailing
    kubernetes-helm
    helmfile
    # secrets (the repo's sops workflow; no keys are provisioned here)
    sops
    age
    ssh-to-age
    # network debugging
    dnsutils # dig
    mtr
    tcpdump
    # general
    btop
    jq
    yq-go
    just
  ];

  # The admin kubeconfig, decrypted to /run/secrets/kubeconfig (read-only,
  # user-owned) and exposed via KUBECONFIG rather than `path =
  # ~/.kube/config`: sops-nix would create ~/.kube as root to hold that
  # symlink, which breaks kubectl's ~/.kube/cache and makes `kubectl config`
  # writes fail confusingly. With KUBECONFIG, ~/.kube stays the user's, and
  # kubectl/helm/helmfile/k9s/stern all honour it. sessionVariables (pam_env)
  # covers SSH, TTY and the LightDM session alike.
  sops.secrets.kubeconfig = {
    owner = "rithviknishad";
    group = "users";
    mode = "0400";
  };
  environment.sessionVariables.KUBECONFIG = config.sops.secrets.kubeconfig.path;
}
