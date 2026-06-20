#
# disko: single ZFS pool STRIPED across BOTH disks (full capacity, NO redundancy).
#
#   sda = WD 120GB   -> ESP (/boot) + zfs partition
#   sdb = Crucial 250GB -> whole-disk zfs partition
#
# Both partitions join one striped vdev => ~342GB usable.
#
# !!! NO FAULT TOLERANCE !!!
# If EITHER disk fails, the ENTIRE pool (including the OS) is lost.
# Both disks are ERASED by disko/nixos-anywhere. Keep off-box backups.
#
# To add redundancy later you'd need to rebuild as a mirror (caps usable at
# the smaller disk) or add disks for RAIDZ.
#
{
  disko.devices = {
    disk = {
      sda = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WDS120G2G0A-00JH30_182216805738";
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

      sdb = {
        type = "disk";
        device = "/dev/disk/by-id/ata-CT250MX500SSD4_1815E1366272";
        content = {
          type = "gpt";
          partitions = {
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
        # No `mode` => top-level vdevs are STRIPED (data spread across both,
        # capacity summed, no redundancy).
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
          "var" = {
            type = "zfs_fs";
            mountpoint = "/var";
            options.mountpoint = "legacy";
          };
          "home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options.mountpoint = "legacy";
          };
        };
      };
    };
  };
}
