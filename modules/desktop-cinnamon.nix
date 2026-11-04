#
# Cinnamon desktop on LightDM (X11), host-agnostic.
#
# Cinnamon (not GNOME/KDE) because g8way came from Linux Mint and it's light
# enough for a dual-core NUC driving a 4K panel. The upstream module already
# pulls in a lot by default (blueman, polkit, gnome-keyring, gvfs, udisks,
# NetworkManager, the slick greeter with Mint themes, DejaVu/Ubuntu fonts) —
# this file only adds what it doesn't, and pins the choices we rely on.
#
# Option names checked against nixpkgs (2026-06): Cinnamon and LightDM still
# live under services.xserver.*; PulseAudio/autologin/defaultSession have
# moved to services.*.
#
{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    desktopManager.cinnamon.enable = true;
    # LightDM is already the fallback DM, but say so: Cinnamon only configures
    # the slick greeter, so another module enabling GDM would silently win.
    displayManager.lightdm.enable = true;
  };
  services.displayManager.defaultSession = "cinnamon";

  # No autologin: the box is reachable from the LAN and has admin
  # credentials (kubeconfig, SSH key) in the session — keep a password
  # between the monitor and them.

  # Audio: PipeWire with the PulseAudio and ALSA shims (Cinnamon's sound
  # applet talks PulseAudio). rtkit lets it get realtime priority.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Cinnamon turns these on with mkDefault; set them explicitly so a host
  # disabling one of them is a visible decision. blueman is the tray applet.
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # Network: Cinnamon's own network applet drives NetworkManager and the
  # module already installs networkmanagerapplet for its session, so
  # programs.nm-applet is deliberately NOT enabled (it'd add a second tray
  # icon). NM itself is enabled per host.

  # No printer anywhere near these boxes; flip on (Cinnamon then adds
  # system-config-printer automatically) if that changes.
  services.printing.enable = false;

  # On top of Cinnamon's DejaVu + Ubuntu: Liberation for metric-compatible
  # web/office text, and colour emoji. Skips noto-fonts/CJK on purpose —
  # they're hundreds of MB, and g8way's closure is pushed over a slow link.
  fonts.packages = [
    pkgs.liberation_ttf
    pkgs.noto-fonts-color-emoji
  ];
}
