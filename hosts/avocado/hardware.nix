#
# Hardware / boot configuration for avocado.
# Intel NUC-class box (i7-8550U), UEFI, SATA SSDs.
#
# Filesystems are defined by disko (./disko.nix) — do NOT add fileSystems here.
#
{ lib, ... }:
{
  boot.initrd.availableKernelModules = [
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
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # --- ZFS ---
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  # Unique 8-hex host id, required for ZFS pool ownership.
  networking.hostId = "b288d857";

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";
}
