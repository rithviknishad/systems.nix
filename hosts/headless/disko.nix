#
# disko: single ZFS pool on ONE disk (NO redundancy).
#
#   nvme0n1 = Samsung PM951 256GB -> ESP (/boot) + zfs partition
#
# !!! THIS DISK IS WORN OUT !!!
# SMART overall-health: FAILED. Critical Warning 0x04 (NVM subsystem
# reliability degraded) and Percentage Used 103%, i.e. past its rated write
# endurance (~72TB written, ~33k power-on hours). Spare is still 100% with 0
# media errors, so it isn't failing right now, but it can go at any time.
#
# So the node is DISPOSABLE: a stateless k3s agent with no PVCs pinned here.
# When the disk dies, replace it and reinstall; don't restore anything.
# The disk is ERASED by disko/nixos-anywhere.
#
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-PM951_NVMe_SAMSUNG_256GB__S29NNXAH395193";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };
    };

    zpool = {
      rpool = {
        type = "zpool";
        # No `mode` => one top-level vdev made of the single partition: plain
        # single-disk pool, no mirror/raidz, no redundancy.
        mode = "";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          mountpoint = "none";
          compression = "zstd";
          acltype = "posixacl";
          xattr = "sa";
          relatime = "on";
          # Opt-in by default: datasets that need rolling snapshots override
          # this to "true" below. modules/zfs.nix owns which those are and
          # reconciles them on a live pool (disko only runs at install time).
          "com.sun:auto-snapshot" = "false";
        };

        datasets = {
          "root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options.mountpoint = "legacy";
          };
          "nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              atime = "off";
            };
          };
          # /var holds the k3s agent state. No PVCs are pinned to this node,
          # so the snapshots only protect against local mistakes. They're
          # not a backup: they die with this disk.
          "var" = {
            type = "zfs_fs";
            mountpoint = "/var";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };
          "home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };
        };
      };
    };
  };
}
