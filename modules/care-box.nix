#
# avocado as the control plane of care-box (CARE on the Raspberry Pi lumine,
# docs/care-box.md). lumine itself is Raspberry Pi OS, configured from
# lumine/ by the `box-*` recipes; this module is avocado's side of that.
#
{ ... }:
{
  # The `box-*` recipes ssh to `lumine` (tailnet MagicDNS) and the LAN name
  # works too. Pinning lumine's host key system-wide means neither a recipe
  # run nor a root-owned service has to trust it on first use. The key is
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
}
