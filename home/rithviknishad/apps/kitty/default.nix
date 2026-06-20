#
# kitty terminal
#
{ pkgs, ... }:
{
  # Nerd Font referenced by the kitty config below.
  home.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  programs.kitty = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 12;
    };
    themeFile = "Catppuccin-Mocha";
    settings = {
      scrollback_lines = 10000;
      enable_audio_bell = false;
      confirm_os_window_close = 0;
      window_padding_width = 6;
    };
  };
}
