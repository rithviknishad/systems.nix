#
# git
#
{ ... }:
{
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "rithviknishad";
        # Change to your real commit email.
        email = "rithviknishad@users.noreply.github.com";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      fetch.prune = true;
    };
  };
}
