#
# Zed editor (the `zeditor` / `zed` command).
#
{ ... }:
{
  programs.zed-editor = {
    enable = true;

    userSettings = {
      vim_mode = false;
      telemetry = {
        metrics = false;
        diagnostics = false;
      };
      theme = "One Dark";
      ui_font_size = 16;
      buffer_font_size = 15;
    };
  };
}
