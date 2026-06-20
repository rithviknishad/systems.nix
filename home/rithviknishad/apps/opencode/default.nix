#
# opencode — terminal AI coding agent.
# No Home Manager module yet; installed as a package.
#
{ pkgs, ... }:
{
  home.packages = [ pkgs.opencode ];
}
