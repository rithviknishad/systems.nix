#
# firefox
#
# Hardened/privacy config adapted from
# https://codeberg.org/adtya/recipes.nix (modules/programs/firefox).
#
# Mapped to Home Manager idioms:
#   - enterprise policies  -> programs.firefox.policies   (./policies.nix)
#   - locked preferences   -> profile settings / user.js  (./prefs.nix)
#
{ ... }:
{
  programs.firefox = {
    enable = true;

    policies = import ./policies.nix;

    profiles.default = {
      id = 0;
      isDefault = true;
      settings = import ./prefs.nix;
    };
  };
}
