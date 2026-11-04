#
# disko: single ZFS pool on ONE disk (NO redundancy).
#
#   main = Gigabyte GP-GSTFS31240GNTD 240GB SATA SSD (Phison) -> ESP (/boot) + zfs
#
# !!! NO FAULT TOLERANCE !!!
# If the disk fails, the ENTIRE pool (including the OS) is lost.
# The disk is ERASED by disko/nixos-anywhere. Keep off-box backups.
#
# SMART at probe time (2026-11-04): PASSED, short self-test passed. 306 power-on
# hours, 137 power cycles, 68 unsafe shutdowns, 757 GiB written, life left 99%
# (endurance used 0%), 0 reallocated/uncorrectable, 0 grown bad blocks (825
# factory), 33°C. 4 interface CRC errors (3 logged at ~17-18h power-on, none
# since): looks like a cable/connector problem, not the flash. Reseat the
# SATA connector if more show up.
#
# To add redundancy later you'd need a second disk (`zpool attach` to make a
# mirror).
#
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/ata-GIGABYTE_GP-GSTFS31240GNTD_SN240808914835";
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
        # No `mode` => a single top-level vdev made of one disk (no
        # redundancy; capacity = that one partition).
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
          # /var holds /var/lib/rancher/k3s (k3s agent state: containerd
          # images, and any local-path PVCs deliberately scheduled here — by
          # default none are; avocado stays the control plane and the home of
          # all stateful workloads). Snapshotted.
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
