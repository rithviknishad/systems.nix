#
# GNOME desktop (Wayland via GDM) for avocado.
# Intel UHD 620 (i7-8550U) graphics.
#
{ lib, pkgs, ... }:
{
  services.xserver.enable = true;

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Don't auto-suspend at the login screen — this box also runs services.
  services.displayManager.gdm.autoSuspend = false;

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Keep our networkd-based DHCP; don't let GNOME pull in NetworkManager
  # (avoids a backend switch that could disrupt the remote connection).
  networking.networkmanager.enable = lib.mkForce false;

  hardware.graphics.enable = true;

  # Audio stack expected by the desktop.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Trim GNOME defaults you likely don't want here.
  environment.gnome.excludePackages = with pkgs; [
    gnome-tour
    epiphany
    geary
  ];

  environment.systemPackages = with pkgs; [
    firefox
    gnome-tweaks
  ];

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    dejavu_fonts
  ];
}
