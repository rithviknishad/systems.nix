#
# Python 3 interpreter.
#
# The nixpkgs `python3` package already ships a bare `python` symlink in its
# bin/ (alongside `python3`), so installing it makes `python` resolve to
# python3 — no shell alias needed, and it works in non-interactive/script
# contexts too.
#
{ pkgs, ... }:
{
  home.packages = [ pkgs.python3 ];
}
