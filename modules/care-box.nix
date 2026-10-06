#
# avocado as the control plane of care-box (CARE on the Raspberry Pi lumine,
# docs/care-box.md). lumine itself is Raspberry Pi OS, configured from
# lumine/ by the `box-*` recipes; this module is avocado's side of that:
# trusting lumine's host key, and pulling nightly backups of it.
#
{ config, pkgs, ... }:
let
  backupDir = "/var/lib/care-box-backups";
  # Snapshots are named by their UTC start time, so names sort by age and
  # retention is a string comparison.
  keepDays = 7;
  textfileDir = "/var/lib/node-exporter/textfile";
  keyFile = config.sops.secrets."care-box-backup/ssh_key".path;

  # Pull one snapshot from lumine into ${backupDir}/<UTC stamp>/:
  #   care.dump   pg_dump -Fc of the `care` database
  #   s3/         VersityGW's tree (uploads + facility files), user.* xattrs
  #               included: they hold each object's S3 metadata
  #   MANIFEST    what was backed up, sizes, what's running on the box
  # The pull goes through the forced command lumine/backup/backup-source.sh,
  # which permits exactly these two reads.
  backupScript = pkgs.writeShellApplication {
    name = "care-box-backup";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      openssh
      rsync
      postgresql_17
    ];
    text = ''
      cd ${backupDir}
      # Only the system-wide known_hosts (lumine pinned above): the service
      # user has no home to keep its own.
      ssh_opts=(-i ${keyFile} -o BatchMode=yes -o IdentitiesOnly=yes
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=20 -o ServerAliveInterval=30)
      remote=care-backup@lumine

      # Leftovers of a run that died mid-way are never valid snapshots.
      find . -mindepth 1 -maxdepth 1 -name '*.partial' -exec rm -rf {} +

      stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
      work=$stamp.partial
      mkdir "$work"
      prev=$(readlink latest || true)

      echo "pg_dump care -> $stamp/care.dump"
      ssh "''${ssh_opts[@]}" "$remote" pg_dump >"$work/care.dump"
      # An interrupted stream still leaves a file behind; a dump only counts
      # if pg_restore can read its whole table of contents.
      toc=$(pg_restore --list "$work/care.dump" | grep -vc '^;')
      echo "care.dump: $(du -h "$work/care.dump" | cut -f1), $toc TOC entries"

      # Unchanged objects become hardlinks into the previous snapshot, so
      # each extra day only costs what changed. Ownership isn't kept (this
      # runs unprivileged); restores chown to versitygw (docs/care-box.md).
      link=()
      if [ -n "$prev" ] && [ -d "$prev/s3" ]; then link=(--link-dest="${backupDir}/$prev/s3"); fi
      echo "rsync s3/ (''${link[*]:-full copy})"
      rsync -rltX --delete --stats -e "ssh ''${ssh_opts[*]}" "''${link[@]}" "$remote:/" "$work/s3/" |
        grep -E '^(Number of (regular )?files|Total file size|Total transferred file size)'

      {
        echo "stamp=$stamp"
        echo "source=lumine (care-box.rithviknishad.dev)"
        echo "db_bytes=$(stat -c %s "$work/care.dump")"
        echo "db_toc_entries=$toc"
        echo "files=$(find "$work/s3" -type f | wc -l)"
        echo "files_bytes=$(du -sb "$work/s3" | cut -f1)"
      } >"$work/MANIFEST"

      mv "$work" "$stamp"
      ln -sfn "$stamp" latest.new
      mv -T latest.new latest
      echo "snapshot $stamp complete"

      # Retention: only after a successful run, so failing backups never
      # eat the last good ones.
      cutoff=$(date -u -d '${toString keepDays} days ago' +%Y-%m-%dT%H%M%SZ)
      for d in 20*Z; do
        [ -d "$d" ] && [ "$d" != "$stamp" ] || continue
        if [[ $d < "$cutoff" ]]; then
          rm -rf "$d"
          echo "pruned $d (older than ${toString keepDays} days)"
        fi
      done
    '';
  };

  # Runs as root after every attempt (ExecStopPost=+): node-exporter's
  # textfile dir is root-only, and the metrics are derived from what's
  # actually on disk rather than trusted from the unprivileged run.
  metricsScript = pkgs.writeShellScript "care-box-backup-metrics" ''
    set -euo pipefail
    PATH=${pkgs.coreutils}/bin:${pkgs.findutils}/bin
    dir=${backupDir}
    tmp=$(mktemp ${textfileDir}/.care_box_backup.prom.XXXXXX)
    trap 'rm -f "$tmp"' EXIT
    ok=0; [ "''${SERVICE_RESULT:-}" = success ] && ok=1
    last=0; db=0; files=0; count=0
    if [ -d "$dir/latest" ]; then
      last=$(stat -c %Y "$dir/latest/MANIFEST")
      db=$(stat -c %s "$dir/latest/care.dump")
      files=$(du -sb "$dir/latest/s3" | cut -f1)
    fi
    count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | wc -l)
    {
      echo "# HELP care_box_backup_last_run_timestamp_seconds When the care-box backup last ran (any outcome)."
      echo "# TYPE care_box_backup_last_run_timestamp_seconds gauge"
      echo "care_box_backup_last_run_timestamp_seconds $(date +%s)"
      echo "# HELP care_box_backup_last_run_success Whether the last care-box backup run succeeded."
      echo "# TYPE care_box_backup_last_run_success gauge"
      echo "care_box_backup_last_run_success $ok"
      echo "# HELP care_box_backup_last_success_timestamp_seconds Completion time of the newest complete snapshot (0 if none)."
      echo "# TYPE care_box_backup_last_success_timestamp_seconds gauge"
      echo "care_box_backup_last_success_timestamp_seconds $last"
      echo "# HELP care_box_backup_snapshots Complete snapshots kept on avocado."
      echo "# TYPE care_box_backup_snapshots gauge"
      echo "care_box_backup_snapshots $count"
      echo "# HELP care_box_backup_latest_db_bytes Size of the newest pg_dump."
      echo "# TYPE care_box_backup_latest_db_bytes gauge"
      echo "care_box_backup_latest_db_bytes $db"
      echo "# HELP care_box_backup_latest_files_bytes Size of the newest uploads snapshot."
      echo "# TYPE care_box_backup_latest_files_bytes gauge"
      echo "care_box_backup_latest_files_bytes $files"
      echo "# HELP care_box_backup_disk_bytes Disk used by all snapshots (hardlinks counted once)."
      echo "# TYPE care_box_backup_disk_bytes gauge"
      echo "care_box_backup_disk_bytes $(du -sb "$dir" | cut -f1)"
    } >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" ${textfileDir}/care_box_backup.prom
    trap - EXIT
  '';
in
{
  # The `box-*` recipes ssh to `lumine` (tailnet MagicDNS) and the LAN name
  # works too. Pinning lumine's host key system-wide means neither a recipe
  # run nor the backup service has to trust it on first use. The key is
  # lumine's /etc/ssh/ssh_host_ed25519_key.pub; if the Pi is ever re-imaged,
  # update it here.
  programs.ssh.knownHosts.lumine = {
    hostNames = [
      "lumine"
      "lumine.orthrus-bass.ts.net"
      "lumine.local"
      "100.67.15.72"
    ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5YOPaaYJIrbs4Wf+2MmhvD4P9F/YKt2NcAERo4FXaf";
  };

  # --- nightly backups of care-box, pulled to avocado -------------------------
  # lumine is a single SD card; a second machine is the actual disaster
  # recovery. A pull rather than a push: lumine holds no credentials for
  # avocado, and the key avocado uses can only read (lumine/backup/).

  users.users.care-box-backup = {
    isSystemUser = true;
    group = "care-box-backup";
  };
  users.groups.care-box-backup = { };

  sops.secrets."care-box-backup/ssh_key" = {
    sopsFile = ../secrets/care-box-backup_ed25519;
    format = "binary";
    owner = "care-box-backup";
    mode = "0400";
  };

  systemd.services.care-box-backup = {
    description = "Pull a backup of care-box (lumine): pg_dump + uploads";
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "care-box-backup";
      Group = "care-box-backup";
      ExecStart = "${backupScript}/bin/care-box-backup";
      ExecStopPost = "+${metricsScript}";
      # ${backupDir}, 0750: patient data in the dumps, readable by root and
      # this service only.
      StateDirectory = "care-box-backups";
      StateDirectoryMode = "0750";
      # A Pi on a flaky link: give a slow pull time, but never hang forever.
      TimeoutStartSec = "2h";
      Nice = 10;
      IOSchedulingClass = "idle";

      # The puller only reads from lumine and writes its own state dir; a
      # compromised lumine feeding it hostile data gets no further.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  systemd.timers.care-box-backup = {
    description = "Nightly care-box backup pull";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # After avocado's own care (02:30) and teleicu (02:45) dumps.
      OnCalendar = "*-*-* 03:15:00";
      RandomizedDelaySec = "10min";
      # Catch up after avocado was off at 03:15.
      Persistent = true;
    };
  };
}
