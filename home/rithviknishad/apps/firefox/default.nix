#
# firefox
#
{ ... }:
{
  programs.firefox = {
    enable = true;

    profiles.default = {
      id = 0;
      isDefault = true;
      settings = {
        "browser.aboutConfig.showWarning" = false;
        "browser.startup.page" = 3; # restore previous session
      };
    };
  };
}
