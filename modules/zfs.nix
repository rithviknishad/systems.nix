#
# ZFS services: scheduled scrub + trim, and auto-snapshots.
# (Pool/dataset layout lives in hosts/avocado/disko.nix.)
#
{ pkgs, ... }:
let
  # Datasets holding IRREPLACEABLE state — these get rolling snapshots.
  #
  #   rpool/var  -> /var, which contains /var/lib/rancher/k3s/storage: every
  #                 k8s PVC on the box (care + teleicu Postgres, MinIO objects,
  #                 immich library, monitoring TSDB, ...). This is the dataset
  #                 that matters.
  #   rpool/home -> user data and repo checkouts.
  #
  # Deliberately NOT snapshotted:
  #   rpool      -> pool root, holds no data (mountpoint=none).
  #   rpool/nix  -> the Nix store; fully reproducible from the flake and very
  #                 high-churn, so snapshots would cost a lot and buy nothing.
  #   rpool/root -> / is ~38M and entirely NixOS-generated; `just rollback`
  #                 already covers it via boot generations.
  snapshotDatasets = [
    "rpool/var"
    "rpool/home"
  ];
  noSnapshotDatasets = [
    "rpool"
    "rpool/nix"
    "rpool/root"
  ];

  # `com.sun:auto-snapshot` is a ZFS dataset property, so it is set once at
  # pool-creation time by disko (hosts/avocado/disko.nix) — and disko only ever
  # runs on a fresh `just install`. A pool created before this intent was
  # declared keeps whatever it was born with, which is exactly how avocado ran
  # for 73 days with the snapshot timers firing every 15 minutes and
  # snapshotting nothing (see docs/storage.md).
  #
  # This oneshot reconciles the live pool with the list above on every boot and
  # every `just deploy`, so "which datasets are snapshotted" stays declarative
  # instead of depending on a `zfs set` somebody remembered to run by hand.
  reconcileScript = pkgs.writeShellScript "zfs-snapshot-properties" ''
    set -euo pipefail
    zfs=${pkgs.zfs}/bin/zfs

    reconcile() {
      want="$1"
      shift
      for ds in "$@"; do
        if ! $zfs list -H -o name "$ds" >/dev/null 2>&1; then
          echo "zfs-snapshot-properties: dataset $ds does not exist, skipping" >&2
          continue
        fi
        have="$($zfs get -H -o value com.sun:auto-snapshot "$ds")"
        if [ "$have" != "$want" ]; then
          echo "zfs-snapshot-properties: $ds com.sun:auto-snapshot $have -> $want"
          $zfs set "com.sun:auto-snapshot=$want" "$ds"
        fi
      done
    }

    reconcile true ${toString snapshotDatasets}
    reconcile false ${toString noSnapshotDatasets}
  '';
in
{
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
  };

  services.zfs.trim.enable = true;

  # Periodic snapshots for datasets tagged com.sun:auto-snapshot=true (tagged
  # by zfs-snapshot-properties below).
  #
  # `daily` is 14 to match the 14-day retention of the per-service pg_dump
  # CronJobs (k8s/*/backup.yaml) — the two layers protect different things
  # (block-level rollback vs. portable logical dump) and it is much easier to
  # reason about recovery when both windows end on the same day.
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4; # 4 x 15min = 1h of fine-grained undo
    hourly = 24; # 1 day
    daily = 14; # matches pg_dump retention
    weekly = 4;
    monthly = 3;
  };

  systemd.services.zfs-snapshot-properties = {
    description = "Reconcile ZFS com.sun:auto-snapshot properties with declared intent";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs.target" ];
    # Ordered before the snapshot timers so a freshly-tagged dataset is picked
    # up by the very next snapshot run rather than the one after it.
    before = [
      "zfs-snapshot-frequent.timer"
      "zfs-snapshot-hourly.timer"
      "zfs-snapshot-daily.timer"
      "zfs-snapshot-weekly.timer"
      "zfs-snapshot-monthly.timer"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = reconcileScript;
    };
  };
}
