#
# GNOME desktop tweaks.
#
# Stops the box from "sleeping" on inactivity. Full system suspend is already
# blocked at the system level (modules/desktop.nix masks the sleep targets);
# what's left is GNOME's per-user idle behaviour — blanking the screen and
# firing idle power actions. Disable both here so the session stays awake.
#
{ lib, ... }:
{
  dconf.settings = {
    # Never blank the screen on idle (0 = never).
    "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;

    # Don't dim or take any power action on idle, on AC or battery.
    "org/gnome/settings-daemon/plugins/power" = {
      idle-dim = false;
      sleep-inactive-ac-type = "nothing";
      sleep-inactive-battery-type = "nothing";
    };

    # Don't auto-activate the screensaver on idle.
    "org/gnome/desktop/screensaver".idle-activation-enabled = false;
  };
}
