#
# Hardware / boot configuration for headless.
# HP 348 G7 laptop (i3-8130U, 2C/4T, 16GB DDR4), Insyde UEFI with Secure Boot
# off, one Samsung PM951 256GB NVMe, Realtek RTL8111/8168h GbE (r8169) as the
# primary NIC. The RTL8822CE Wi-Fi is present but unused.
#
# The SATA controller is in Intel RST "RAID" mode, but `ahci` still binds to
# it. There's no SATA disk today; switch it to AHCI in the BIOS if one is added.
#
# Filesystems are defined by disko (./disko.nix) — do NOT add fileSystems here.
#
{ lib, ... }:
{
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Bootloader: systemd-boot on UEFI (ESP mounted at /boot by disko).
  # systemd-boot also installs the EFI/BOOT/BOOTX64.EFI fallback, which the HP
  # firmware boots via its generic "Internal Hard Disk" entry if it ever drops
  # the NVRAM entry.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # --- ZFS ---
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  # Unique 8-hex host id, required for ZFS pool ownership.
  networking.hostId = "3f4f3cd3";

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.cpu.intel.updateMicrocode = true;
  # r8169 loads rtl8168h-2 firmware from linux-firmware (the rtw88 Wi-Fi
  # needs it too, if it's ever used).
  hardware.enableRedistributableFirmware = true;
}
