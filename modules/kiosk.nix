#
# Display kiosk: the built-in screen always shows live system stats.
#
# Replaces the former GNOME desktop (modules/desktop.nix). cage — a
# single-application Wayland compositor — starts at boot on tty1 and runs
# btop fullscreen in a foot terminal, as a dedicated unprivileged user.
#
# Hardening properties vs. a desktop session:
#   - No desktop, no login screen, no screensaver — nothing to lock or idle.
#   - The `kiosk` user has no password, no SSH keys, and no sudo; the only
#     thing reachable from the console is btop, scoped to what `kiosk` can
#     see and signal.
#   - Admin access stays SSH (key-only). VT switching is left enabled so a
#     getty (Ctrl+Alt+F2) remains reachable with physical access if the
#     network ever dies.
#
{ pkgs, ... }:
{
  services.cage = {
    enable = true;
    user = "kiosk";
    program = "${pkgs.foot}/bin/foot ${pkgs.btop}/bin/btop";
    # -s: allow VT switching for on-box recovery via getty.
    extraArguments = [ "-s" ];
  };

  users.users.kiosk = {
    isNormalUser = true;
    description = "Display kiosk (btop)";
    # No password and no keys: this account exists only to own the cage
    # session; it cannot log in anywhere.
  };

  # Never auto-suspend or hibernate. Idle suspend is what dropped this box off
  # the network; masking the sleep targets prevents anything (logind idle, lid
  # close, manual) from suspending it.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Intel UHD 620 (i7-8550U).
  hardware.graphics.enable = true;

  # foot's default font is fontconfig's "monospace"; give it a real one.
  fonts.packages = [ pkgs.dejavu_fonts ];

  # btop for interactive (SSH) use too; foot's terminfo so TERM=foot resolves
  # in regular shells.
  environment.systemPackages = [
    pkgs.btop
    pkgs.foot.terminfo
  ];
}
