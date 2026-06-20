#
# ZFS services: scheduled scrub + trim, and auto-snapshots.
# (Pool/dataset layout lives in hosts/avocado/disko.nix.)
#
{ ... }:
{
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
  };

  services.zfs.trim.enable = true;

  # Periodic snapshots for datasets tagged com.sun:auto-snapshot=true.
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4;
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 3;
  };
}
