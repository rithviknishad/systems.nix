#
# sops-nix: encrypted secrets management (host-agnostic).
#
# Each host reads ../secrets/<hostname>.yaml (recipients in .sops.yaml): the
# admin key plus that host's own key, so no host can decrypt another's file.
#
# How the host decrypts is per host:
#   avocado        -> a dedicated age key at /var/lib/sops-nix/key.txt,
#                     provisioned out-of-band (set in hosts/avocado).
#   g8way/headless -> sops-nix's default: the age identity derived from the
#                     SSH host key (/etc/ssh/ssh_host_ed25519_key). Nothing to
#                     provision — after install, `ssh-keyscan -t ed25519 <ip> |
#                     ssh-to-age` gives the recipient for .sops.yaml. A
#                     reinstall regenerates the host key, so re-add + rekey.
#
{ inputs, config, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    defaultSopsFile = ../secrets + "/${config.networking.hostName}.yaml";
    defaultSopsFormat = "yaml";
  };

  # User password hash. `neededForUsers` decrypts this early enough for
  # user account creation (before normal secrets are mounted).
  sops.secrets."users/rithviknishad/hashed-password".neededForUsers = true;
  users.users.rithviknishad.hashedPasswordFile =
    config.sops.secrets."users/rithviknishad/hashed-password".path;
}
