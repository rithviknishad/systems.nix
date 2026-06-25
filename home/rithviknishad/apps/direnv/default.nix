#
# direnv — per-directory environments, with nix-direnv for fast `use flake`.
#
# Shell hook is wired into zsh automatically (enableZshIntegration).
#
{ ... }:
{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableZshIntegration = true;
  };
}
