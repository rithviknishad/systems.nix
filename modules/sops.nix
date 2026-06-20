#
# sops-nix: encrypted secrets management.
#
# Secrets live in ../secrets/avocado.yaml (encrypted via .sops.yaml).
# The host decrypts them at activation using its age key at
# /var/lib/sops-nix/key.txt (provisioned out-of-band, never in the repo).
#
{ inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    defaultSopsFile = ../secrets/avocado.yaml;
    defaultSopsFormat = "yaml";

    age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = false;
    };
  };

  # User password hash. `neededForUsers` decrypts this early enough for
  # user account creation (before normal secrets are mounted).
  sops.secrets."users/rithviknishad/hashed-password".neededForUsers = true;
}
