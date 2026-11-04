#
# Host-side monitoring glue for the in-cluster VictoriaMetrics stack
# (k8s/monitoring/). The stack's node-exporter DaemonSet reads Prometheus
# "textfile" metrics from /var/lib/node-exporter/textfile (mounted read-only
# into the pod via values.yaml). node-exporter's built-in collectors don't
# cover per-pool ZFS health or SMART, so we generate those here:
#
#   - node_zfs_zpool_state   -> ZFS pool health   (zfs-vmrules.yaml)
#   - smartmon_*             -> SMART disk health  (smart-vmrules.yaml)
#
# These make the ZFSPool* and Smartmon* alerts fire — critical for avocado's
# no-redundancy rpool stripe, where a single failing disk destroys the pool.
# Imported by every k3s node (avocado, g8way, headless): node-exporter runs on
# all of them, and each is a single point of failure on its own disk(s).
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.systems.monitoring;
  textfileDir = "/var/lib/node-exporter/textfile";

  # node-exporter runs as a non-root user in-cluster, so the .prom files must
  # be world-readable (mktemp defaults to 0600). Every generator chmods 0644
  # before the atomic mv.
  zfsTextfileScript = pkgs.writeShellScript "zfs-textfile-metrics" ''
    set -euo pipefail

    dir=${textfileDir}
    states="online degraded faulted offline removed unavail suspended"

    tmp="$(${pkgs.coreutils}/bin/mktemp "$dir/.zfs.prom.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT

    {
      echo "# HELP node_zfs_zpool_state ZFS pool health state (1 = current state)."
      echo "# TYPE node_zfs_zpool_state gauge"
      while read -r name health; do
        cur="$(echo "$health" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')"
        for s in $states; do
          if [ "$s" = "$cur" ]; then v=1; else v=0; fi
          printf 'node_zfs_zpool_state{zpool="%s",state="%s"} %d\n' "$name" "$s" "$v"
        done
      done < <(${pkgs.zfs}/bin/zpool list -H -o name,health)

      # Pool capacity. Snapshots retain freed blocks, so a pool that was
      # comfortable can fill up quietly once rolling snapshots are enabled
      # (modules/zfs.nix) — these back the ZFSPoolFillingUp/CriticallyFull
      # alerts. -p gives exact bytes instead of human-rounded values.
      echo "# HELP node_zfs_zpool_size_bytes Total size of the ZFS pool in bytes."
      echo "# TYPE node_zfs_zpool_size_bytes gauge"
      while read -r name size _alloc _free; do
        printf 'node_zfs_zpool_size_bytes{zpool="%s"} %s\n' "$name" "$size"
      done < <(${pkgs.zfs}/bin/zpool list -H -p -o name,size,alloc,free)

      echo "# HELP node_zfs_zpool_allocated_bytes Allocated bytes in the ZFS pool."
      echo "# TYPE node_zfs_zpool_allocated_bytes gauge"
      while read -r name _size alloc _free; do
        printf 'node_zfs_zpool_allocated_bytes{zpool="%s"} %s\n' "$name" "$alloc"
      done < <(${pkgs.zfs}/bin/zpool list -H -p -o name,size,alloc,free)

      echo "# HELP node_zfs_zpool_free_bytes Free bytes in the ZFS pool."
      echo "# TYPE node_zfs_zpool_free_bytes gauge"
      while read -r name _size _alloc free; do
        printf 'node_zfs_zpool_free_bytes{zpool="%s"} %s\n' "$name" "$free"
      done < <(${pkgs.zfs}/bin/zpool list -H -p -o name,size,alloc,free)

      # Per-dataset snapshot coverage, for datasets that OPT IN via
      # com.sun:auto-snapshot=true. This exists because the failure mode that
      # cost us the care database was silent: the snapshot timers ran green
      # every 15 minutes for 73 days while creating zero snapshots. Counting
      # them and tracking the newest one turns that into an alertable signal
      # (ZFSSnapshotsMissing / ZFSSnapshotsStale).
      echo "# HELP node_zfs_dataset_snapshot_count Number of snapshots for a dataset tagged com.sun:auto-snapshot=true."
      echo "# TYPE node_zfs_dataset_snapshot_count gauge"
      while read -r ds tagged; do
        [ "$tagged" = "true" ] || continue
        n="$(${pkgs.zfs}/bin/zfs list -H -d 1 -t snapshot -o name "$ds" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)"
        printf 'node_zfs_dataset_snapshot_count{dataset="%s"} %s\n' "$ds" "$n"
      done < <(${pkgs.zfs}/bin/zfs list -H -o name,com.sun:auto-snapshot)

      echo "# HELP node_zfs_dataset_latest_snapshot_timestamp_seconds Creation time of the newest snapshot for a tagged dataset (0 if none)."
      echo "# TYPE node_zfs_dataset_latest_snapshot_timestamp_seconds gauge"
      while read -r ds tagged; do
        [ "$tagged" = "true" ] || continue
        latest="$(${pkgs.zfs}/bin/zfs list -H -p -d 1 -t snapshot -o creation -s creation "$ds" 2>/dev/null | ${pkgs.coreutils}/bin/tail -n 1)"
        printf 'node_zfs_dataset_latest_snapshot_timestamp_seconds{dataset="%s"} %s\n' "$ds" "''${latest:-0}"
      done < <(${pkgs.zfs}/bin/zfs list -H -o name,com.sun:auto-snapshot)

      echo "# HELP node_zfs_textfile_scrape_success Whether the ZFS textfile generator last ran successfully."
      echo "# TYPE node_zfs_textfile_scrape_success gauge"
      echo "node_zfs_textfile_scrape_success 1"
    } > "$tmp"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    # Atomic swap (same filesystem) so node-exporter never reads a partial file.
    ${pkgs.coreutils}/bin/mv "$tmp" "$dir/zfs.prom"
    trap - EXIT
  '';

  # SMART disk health via smartctl JSON. Emits the smartmon_* family (a subset
  # of the well-known node-exporter smartmon.sh script) for every scanned disk,
  # plus NVMe wear/health-log gauges (smartmon_nvme_*).
  smartTextfileScript = pkgs.writeShellScript "smart-textfile-metrics" ''
    set -euo pipefail

    dir=${textfileDir}
    smartctl=${pkgs.smartmontools}/bin/smartctl
    jq=${pkgs.jq}/bin/jq
    acked=${lib.escapeShellArg (lib.concatStringsSep " " cfg.smart.acknowledgedFailingSerials)}

    tmp="$(${pkgs.coreutils}/bin/mktemp "$dir/.smartmon.prom.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT

    # The Prometheus text parser requires each metric family's samples to be
    # contiguous, so collect per-family lines into separate files and emit them
    # grouped (not interleaved per disk).
    f_health="$(${pkgs.coreutils}/bin/mktemp)"
    f_temp="$(${pkgs.coreutils}/bin/mktemp)"
    f_poh="$(${pkgs.coreutils}/bin/mktemp)"
    f_run="$(${pkgs.coreutils}/bin/mktemp)"
    f_cw="$(${pkgs.coreutils}/bin/mktemp)"
    f_media="$(${pkgs.coreutils}/bin/mktemp)"
    f_used="$(${pkgs.coreutils}/bin/mktemp)"
    f_spare="$(${pkgs.coreutils}/bin/mktemp)"
    trap 'rm -f "$tmp" "$f_health" "$f_temp" "$f_poh" "$f_run" "$f_cw" "$f_media" "$f_used" "$f_spare"' EXIT

    # `smartctl --scan -j` lists devices with their access type (sat/nvme/...).
    $smartctl --scan -j 2>/dev/null \
      | $jq -r '.devices[]? | "\(.name) \(.type)"' \
      | while read -r devname devtype; do
          [ -n "$devname" ] || continue

          # The scanned type is often "scsi" for SATA drives behind an AHCI
          # controller, which yields no SMART self-assessment. Try a few
          # access types and keep the first that returns smart_status.
          info=""
          usedtype="$devtype"
          for t in sat "$devtype" auto nvme; do
            probe="$($smartctl -H -A -i -j -d "$t" "$devname" 2>/dev/null || true)"
            [ -n "$probe" ] || continue
            # Not `.smart_status.passed // empty`: jq's `//` treats false as
            # missing, so a FAILED disk would never win and the first
            # (wrong-type, status-less) probe got reported as -1 / unknown.
            passed="$(echo "$probe" | $jq -r 'if .smart_status.passed == null then empty else .smart_status.passed end')"
            if [ -n "$passed" ]; then info="$probe"; usedtype="$t"; break; fi
            [ -z "$info" ] && info="$probe" && usedtype="$t"
          done
          [ -n "$info" ] || continue

          d="$(${pkgs.coreutils}/bin/basename "$devname")"
          model="$(echo "$info" | $jq -r '.model_name // "unknown"')"
          serial="$(echo "$info" | $jq -r '.serial_number // "unknown"')"
          healthy="$(echo "$info" | $jq -r 'if .smart_status.passed == true then 1 elif .smart_status.passed == false then 0 else -1 end')"
          temp="$(echo "$info" | $jq -r '.temperature.current // empty')"
          poh="$(echo "$info" | $jq -r '.power_on_time.hours // empty')"

          case " $acked " in
            *" $serial "*) ack=true ;;
            *) ack=false ;;
          esac

          printf 'smartmon_device_smart_healthy{disk="%s",type="%s",model="%s",serial="%s",acknowledged="%s"} %s\n' \
            "$d" "$usedtype" "$model" "$serial" "$ack" "$healthy" >> "$f_health"
          [ -n "$temp" ] && printf 'smartmon_temperature_celsius{disk="%s"} %s\n' "$d" "$temp" >> "$f_temp"
          [ -n "$poh" ] && printf 'smartmon_power_on_hours{disk="%s"} %s\n' "$d" "$poh" >> "$f_poh"
          printf 'smartmon_smartctl_run{disk="%s"} %s\n' "$d" "$(${pkgs.coreutils}/bin/date +%s)" >> "$f_run"

          # NVMe health log. The overall verdict is just "any critical-warning
          # bit set", so it can't tell "worn past rated endurance but fine"
          # (headless) from "about to go read-only". Export the parts so alerts
          # can still catch an acknowledged disk getting worse.
          cw="$(echo "$info" | $jq -r '.nvme_smart_health_information_log.critical_warning // empty')"
          if [ -n "$cw" ]; then
            bit=0
            for flag in available_spare temperature reliability_degraded read_only volatile_memory_backup; do
              printf 'smartmon_nvme_critical_warning{disk="%s",flag="%s"} %d\n' "$d" "$flag" $(( (cw >> bit) & 1 )) >> "$f_cw"
              bit=$((bit + 1))
            done
            echo "$info" | $jq -r --arg d "$d" '.nvme_smart_health_information_log
              | "smartmon_nvme_media_errors{disk=\"\($d)\"} \(.media_errors)"' >> "$f_media"
            echo "$info" | $jq -r --arg d "$d" '.nvme_smart_health_information_log
              | "smartmon_nvme_percentage_used{disk=\"\($d)\"} \(.percentage_used)"' >> "$f_used"
            echo "$info" | $jq -r --arg d "$d" '.nvme_smart_health_information_log
              | "smartmon_nvme_available_spare_percent{disk=\"\($d)\",kind=\"current\"} \(.available_spare)",
                "smartmon_nvme_available_spare_percent{disk=\"\($d)\",kind=\"threshold\"} \(.available_spare_threshold)"' >> "$f_spare"
          fi
        done

    {
      echo "# HELP smartmon_device_smart_healthy SMART overall-health self-assessment (1 = PASSED, 0 = FAILED, -1 = unknown)."
      echo "# TYPE smartmon_device_smart_healthy gauge"
      ${pkgs.coreutils}/bin/cat "$f_health"
      echo "# HELP smartmon_temperature_celsius Current drive temperature in celsius."
      echo "# TYPE smartmon_temperature_celsius gauge"
      ${pkgs.coreutils}/bin/cat "$f_temp"
      echo "# HELP smartmon_power_on_hours Drive power-on time in hours."
      echo "# TYPE smartmon_power_on_hours gauge"
      ${pkgs.coreutils}/bin/cat "$f_poh"
      echo "# HELP smartmon_smartctl_run Unix timestamp of the last smartctl run per device."
      echo "# TYPE smartmon_smartctl_run gauge"
      ${pkgs.coreutils}/bin/cat "$f_run"
      echo "# HELP smartmon_nvme_critical_warning NVMe critical-warning bits, one series per flag (1 = set)."
      echo "# TYPE smartmon_nvme_critical_warning gauge"
      ${pkgs.coreutils}/bin/cat "$f_cw"
      echo "# HELP smartmon_nvme_media_errors NVMe media and data integrity errors (lifetime count)."
      echo "# TYPE smartmon_nvme_media_errors gauge"
      ${pkgs.coreutils}/bin/cat "$f_media"
      echo "# HELP smartmon_nvme_percentage_used NVMe estimate of rated endurance used (can exceed 100)."
      echo "# TYPE smartmon_nvme_percentage_used gauge"
      ${pkgs.coreutils}/bin/cat "$f_used"
      echo "# HELP smartmon_nvme_available_spare_percent NVMe spare capacity left (kind=current) and the vendor threshold (kind=threshold)."
      echo "# TYPE smartmon_nvme_available_spare_percent gauge"
      ${pkgs.coreutils}/bin/cat "$f_spare"
    } > "$tmp"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" "$dir/smartmon.prom"
    trap - EXIT
  '';
in
{
  options.systems.monitoring.smart.acknowledgedFailingSerials = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "S29NNXAH395193" ];
    description = ''
      Serial numbers of disks whose FAILED SMART verdict is known and accepted
      (e.g. a worn-out SSD in a disposable node). They are labelled
      acknowledged="true", which SmartDeviceUnhealthy skips so it doesn't page
      forever; the NVMe wear alerts still fire if the disk gets worse.
    '';
  };

  config = {
    # Ensure the textfile directory exists (also a hostPath in values.yaml).
    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root -"
    ];

    systemd.services.zfs-textfile-metrics = {
      description = "Write ZFS pool health metrics for node-exporter's textfile collector";
      after = [ "zfs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = zfsTextfileScript;
      };
    };

    systemd.timers.zfs-textfile-metrics = {
      description = "Periodically refresh ZFS textfile metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        Persistent = true;
      };
    };

    systemd.services.smart-textfile-metrics = {
      description = "Write SMART disk-health metrics for node-exporter's textfile collector";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = smartTextfileScript;
      };
    };

    systemd.timers.smart-textfile-metrics = {
      description = "Periodically refresh SMART textfile metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        # SMART attributes change slowly; every 5 minutes is plenty.
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };
  };
}
