# TEMPORARY (care-pi): let avocado build aarch64-linux (Raspberry Pi) closures
# through qemu emulation. Safe to remove once the Pi install is done.
{ ... }:
{
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
}
