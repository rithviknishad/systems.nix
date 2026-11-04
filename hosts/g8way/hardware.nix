#
# Hardware / boot configuration for g8way.
# Intel NUC5i3RYB (5th gen, Broadwell i3-5010U 2C/4T, HD Graphics 5500),
# 16GB RAM, UEFI (BIOS RYBDWi35.86A.0363, 2017), single 2.5" SATA SSD.
# Intel I218-V GbE (e1000e) + Intel 7265 Wi-Fi/BT (iwlwifi/btusb).
#
# Filesystems are defined by disko (./disko.nix) — do NOT add fileSystems here.
# The desktop itself is modules/desktop-cinnamon.nix; only the GPU bits that
# are specific to this machine live here.
#
# Display: an LG 4K monitor. The NUC5's HDMI is 1.4 (4K at 30 Hz at best), so
# it must be on mini-DisplayPort for 4K60 — nothing to configure, just cable.
#
{ lib, pkgs, ... }:
{
  # No NVMe (the NUC5 M.2 slot is SATA-only) and no card reader. The SATA
  # controller reports "RAID mode" (8086:282a) in firmware but binds to ahci.
  # ehci_pci: the NUC5 still routes some USB ports through an EHCI controller.
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ehci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Bootloader: systemd-boot on UEFI (ESP mounted at /boot by disko).
  # Secure Boot is off (platform in Setup Mode), so no shim is needed.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # --- ZFS ---
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  # Unique 8-hex host id, required for ZFS pool ownership.
  networking.hostId = "eae70a8a";

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.cpu.intel.updateMicrocode = true;
  # iwlwifi (Intel 7265) and its Bluetooth half need linux-firmware blobs.
  hardware.enableRedistributableFirmware = true;

  # Intel HD 5500 (Gen8/Broadwell): the kernel's modesetting X driver plus
  # VA-API for video decode in Firefox/Celluloid. iHD (intel-media-driver)
  # still supports Broadwell and is the maintained one; libva would otherwise
  # probe i965 first, hence LIBVA_DRIVER_NAME. i965 (intel-vaapi-driver) stays
  # installed as a fallback — `LIBVA_DRIVER_NAME=i965 vainfo` if iHD regresses.
  hardware.graphics = {
    enable = true;
    extraPackages = [
      pkgs.intel-media-driver
      pkgs.intel-vaapi-driver
    ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
  environment.systemPackages = [ pkgs.libva-utils ]; # vainfo
}
