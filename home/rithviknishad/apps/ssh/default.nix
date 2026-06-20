#
# SSH client settings (portable — reuse this module on any machine).
#
# The private key itself is delivered out-of-band by sops-nix at the system
# level (see modules/sops.nix), decrypted to the path below and owned by the
# user. This module only references it, so the config stays machine-agnostic.
#
{ ... }:
let
  identityFile = "/run/secrets/rithviknishad/ssh_id_ed25519";
in
{
  programs.ssh = {
    enable = true;
    # Define our own "*" defaults instead of HM's built-in ones.
    enableDefaultConfig = false;

    settings = {
      # Global defaults (uses OpenSSH directive names).
      "*" = {
        IdentityFile = identityFile;
        AddKeysToAgent = "yes";
        ForwardAgent = false;
        Compression = false;
        ServerAliveInterval = 60;
        ServerAliveCountMax = 3;
        HashKnownHosts = true;
        ControlMaster = "auto";
        ControlPath = "~/.ssh/sockets/%r@%h-%p";
        ControlPersist = "10m";
      };

      "github.com" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = identityFile;
        IdentitiesOnly = true;
      };
    };
  };

  # Ensure the ControlMaster socket directory exists.
  home.file.".ssh/sockets/.keep".text = "";
}
