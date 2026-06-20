#
# zsh shell.
# NOTE: the login shell is set at the system level in
# users/rithviknishad.nix (shell = zsh + programs.zsh.enable).
#
{ ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history = {
      size = 50000;
      save = 50000;
      ignoreDups = true;
      share = true;
    };

    shellAliases = {
      ll = "ls -alh";
      la = "ls -A";
      gs = "git status";
      gd = "git diff";
    };

    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [
        "git"
        "sudo"
      ];
    };
  };
}
