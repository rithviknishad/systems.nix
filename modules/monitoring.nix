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
#
{
  pkgs,
  ...
}:
let
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
  # of the well-known node-exporter smartmon.sh script) for every scanned disk.
  smartTextfileScript = pkgs.writeShellScript "smart-textfile-metrics" ''
    set -euo pipefail

    dir=${textfileDir}
    smartctl=${pkgs.smartmontools}/bin/smartctl
    jq=${pkgs.jq}/bin/jq

    tmp="$(${pkgs.coreutils}/bin/mktemp "$dir/.smartmon.prom.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT

    # The Prometheus text parser requires each metric family's samples to be
    # contiguous, so collect per-family lines into separate files and emit them
    # grouped (not interleaved per disk).
    f_health="$(${pkgs.coreutils}/bin/mktemp)"
    f_temp="$(${pkgs.coreutils}/bin/mktemp)"
    f_poh="$(${pkgs.coreutils}/bin/mktemp)"
    f_run="$(${pkgs.coreutils}/bin/mktemp)"
    trap 'rm -f "$tmp" "$f_health" "$f_temp" "$f_poh" "$f_run"' EXIT

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
            passed="$(echo "$probe" | $jq -r '.smart_status.passed // empty')"
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

          printf 'smartmon_device_smart_healthy{disk="%s",type="%s",model="%s",serial="%s"} %s\n' \
            "$d" "$usedtype" "$model" "$serial" "$healthy" >> "$f_health"
          [ -n "$temp" ] && printf 'smartmon_temperature_celsius{disk="%s"} %s\n' "$d" "$temp" >> "$f_temp"
          [ -n "$poh" ] && printf 'smartmon_power_on_hours{disk="%s"} %s\n' "$d" "$poh" >> "$f_poh"
          printf 'smartmon_smartctl_run{disk="%s"} %s\n' "$d" "$(${pkgs.coreutils}/bin/date +%s)" >> "$f_run"
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
    } > "$tmp"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" "$dir/smartmon.prom"
    trap - EXIT
  '';
in
{
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
}
