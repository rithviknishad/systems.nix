#
# Docker — a BUILD tool only, not a runtime.
#
# Some k8s workloads need images that upstream doesn't publish in a usable
# form (care backend with plugins baked in at build time, care_fe with the
# API URL compiled into the bundle, ...). Those are built ON the box with
# `docker build` and imported straight into k3s's containerd via
# `k3s ctr images import` — no registry involved (same "no registry" idea as
# the Nix-built bingo image, but for upstream Dockerfiles that are impractical
# to nixify). See the `care-images` recipes in the justfile.
#
# Workloads themselves always run under k3s; nothing is `docker run` here.
#
{ ... }:
{
  virtualisation.docker = {
    enable = true;
    # Multi-stage node/python builds leave chunky dangling layers; prune them
    # weekly so the striped rpool isn't slowly eaten by build cache.
    autoPrune.enable = true;
  };

  # The docker group is root-equivalent by design; acceptable on this
  # single-admin box where the same user already holds sudo.
  users.users.rithviknishad.extraGroups = [ "docker" ];
}
