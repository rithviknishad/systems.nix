#
# Home Manager configuration for rithviknishad.
# Each app is its own module under ./apps/<name>.
#
{ ... }:
{
  imports = [
    ./apps/git
    ./apps/kitty
    ./apps/firefox
    ./apps/zeditor
    ./apps/opencode
    ./apps/lens
    ./apps/zsh
    ./apps/ssh
    ./apps/claude-code
  ];

  home.username = "rithviknishad";
  home.homeDirectory = "/home/rithviknishad";

  # The HM release this profile targets. Don't change after first activation.
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
}
