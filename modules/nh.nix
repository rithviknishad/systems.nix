#
# nh — the "nix helper" CLI, for managing this box from the in-home git clone.
#
# The repo is cloned to /home/rithviknishad/systems.nix, and /etc/nixos is a
# symlink to it. nh is pointed at /etc/nixos (its flake path can't end in
# `.nix`, and going through the symlink keeps the natural repo dir name).
#
#   nh os switch        # build + activate
#   nh os boot          # stage for next boot
#   nh os build         # build only (no sudo)
#
{ ... }:
{
  programs.nh = {
    enable = true;
    flake = "/etc/nixos";
  };

  # /etc/nixos -> the in-home git clone.
  systemd.tmpfiles.rules = [
    "L+ /etc/nixos - - - - /home/rithviknishad/systems.nix"
  ];
}
