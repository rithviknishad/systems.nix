#
# k3s agent — a worker node joining avocado's control plane over the tailnet.
#
# Shared settings (token, tailnet node-ip, flannel over tailscale0) live in
# ./k3s-common.nix. Imported by g8way and headless.
#
# Agents are TAINTED, so nothing schedules here unless it explicitly opts in:
#   tolerations: [{ key: rithviknishad.dev/opt-in, operator: Exists, effect: NoSchedule }]
#   (+ a nodeSelector such as kubernetes.io/hostname: headless)
# Why opt-in rather than letting the scheduler spread things out:
#   - Several workloads can only run on avocado: their images are imported
#     straight into avocado's containerd with `imagePullPolicy: Never` (CARE,
#     TeleICU, onvif-console, zerodha-kite), so a pod landing on an agent
#     would sit in ErrImageNeverPull.
#   - Every PVC is local-path on avocado's pool; the agents hold no state.
#   - headless's SSD has failed SMART, and g8way is a desktop someone uses.
# DaemonSets that tolerate every taint (node-exporter) still land here; that's
# wanted, it's how the agents show up in monitoring.
#
# Taints and labels from flags are applied when the node first REGISTERS
# only. To change them on an existing node, use `kubectl taint` /
# `kubectl label` too (or delete the node object and restart k3s).
#
{ ... }:
{
  imports = [ ./k3s-common.nix ];

  services.k3s = {
    role = "agent";
    # MagicDNS name; the API cert already carries it (--tls-san=avocado).
    serverAddr = "https://avocado:6443";
    nodeTaint = [ "rithviknishad.dev/opt-in=true:NoSchedule" ];
  };
}
