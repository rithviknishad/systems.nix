#
# disko ZFS layout for avocado.
#
# TARGET DISK: sda = WD 120GB (currently empty on the Ubuntu box).
# This is pinned by /dev/disk/by-id so disko never touches the wrong disk.
#
# To install on the 250GB Crucial (sdb) instead, swap `device` for:
#   /dev/disk/by-id/ata-CT250MX500SSD4_1815E1366272
# (that wipes the current Ubuntu install).
#
# WARNING: running disko/nixos-anywhere ERASES this disk completely.
#
{
  disko.devices = {
    disk = {
      main = {
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
    };

    zpool = {
      rpool = {
        type = "zpool";
        # Single-disk pool. (No mode = stripe/single vdev.)
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
