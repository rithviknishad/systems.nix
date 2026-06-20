#
# OpenSSH server. Key-only auth; required for nixos-anywhere and
# for ongoing `nixos-rebuild --target-host`.
#
{ ... }:
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    openFirewall = true;
  };
}
