#
# Base system configuration shared across hosts.
#
{ pkgs, ... }:
{
  # Flakes + the modern nix CLI.
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  time.timeZone = "Asia/Kolkata";
  i18n.defaultLocale = "en_US.UTF-8";

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    wget
    htop
    tmux
    rsync
  ];

  # Firewall on; SSH port opened in modules/ssh.nix.
  networking.firewall.enable = true;
}
