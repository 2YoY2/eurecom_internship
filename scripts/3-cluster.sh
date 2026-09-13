#!/usr/bin/env bash
# Install k3s, configured for a real-time RAN host.
#
#   ./scripts/3-cluster.sh
#
# Three decisions worth knowing about:
#
# 1. --docker. The DU images are built locally (oai-gnb-aerial:latest) and the
#    Aerial image is 26 GB. Using the existing Docker daemon means k3s sees
#    those images directly; with the default containerd you would have to
#    export and re-import 26 GB every rebuild.
#
# 2. k3s is pinned to the housekeeping cores. The kernel isolates 4-19 for the
#    RAN; a control plane scheduling itself onto an Aerial worker core causes
#    late slots. systemd CPUAffinity keeps k3s on the same cores as the rest
#    of the OS.
#
# 3. traefik and servicelb are disabled. A DU uses host networking; an ingress
#    controller is dead weight and one more thing binding ports.
#
# This does NOT touch driver, kernel, hugepages, PTP or NIC configuration.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOUSEKEEPING="${HOUSEKEEPING_CPUS:-0-3}"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

if command -v k3s >/dev/null 2>&1; then
  echo ">> k3s already installed: $(k3s --version | head -1)"
else
  echo ">> installing k3s (docker runtime, no traefik/servicelb, kubeconfig readable)"
  curl -sfL https://get.k3s.io | sh -s - \
    --docker \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    || { echo "k3s install failed" >&2; exit 1; }
fi

# NOT pinning k3s with CPUAffinity, deliberately.
#
# It looks prudent -- keep the control plane off the RAN cores -- but it is
# redundant and it bites. Redundant because isolcpus already removes those
# cores from the default affinity mask, so k3s and every ordinary process
# lands on the housekeeping cores anyway. It bites because CPUAffinity is
# inherited by everything k3s spawns, and a control plane confined to four
# cores can fail to finish the heavy reconciliation after a cold start: on
# this host it produced a crash loop of 79 restarts, whose symptoms
# (apiserver refusing connections, pods stuck ContainerCreating) look
# nothing like a CPU constraint.
#
# If you ever do want it, add the drop-in yourself and watch NRestarts:
#   /etc/systemd/system/k3s.service.d/cpu-affinity.conf  ->  CPUAffinity=0-3
if [ -f /etc/systemd/system/k3s.service.d/cpu-affinity.conf ]; then
  echo ">> removing a previously-added k3s CPUAffinity drop-in (see comment)"
  sudo rm -f /etc/systemd/system/k3s.service.d/cpu-affinity.conf
  sudo systemctl daemon-reload
  sudo systemctl restart k3s
  sleep 5
fi

echo ">> kubeconfig"
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config" 2>/dev/null
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config" 2>/dev/null
chmod 600 "$HOME/.kube/config" 2>/dev/null
grep -q 'KUBECONFIG' "$HOME/.bashrc" 2>/dev/null || \
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
export KUBECONFIG="$HOME/.kube/config"

echo ">> waiting for the node"
for i in $(seq 1 30); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl get nodes -o wide 2>&1 | head -3

# ---------------------------------------------------------------- GPU access
echo
echo ">> GPU scheduling"
# With --docker, a pod gets the GPU only if Docker's DEFAULT runtime is nvidia.
# We do NOT change /etc/docker/daemon.json here: this host runs other people's
# containers, and switching the default runtime under them is not ours to do.
if docker info 2>/dev/null | grep -qi 'Default Runtime: nvidia'; then
  echo "   OK: docker default runtime is nvidia — containers get the GPU directly"
  # The device plugin is OPT-IN, and off by default on purpose.
  #
  # It cannot run on a unified-memory GPU such as GB10: it builds its device
  # map by querying per-device memory and NVML answers "Not Supported", so the
  # DaemonSet crash-loops and the node never advertises nvidia.com/gpu at all.
  # (nvidia-smi shows the same thing as "Memory-Usage: Not Supported".)
  #
  # It is also not needed on a dedicated RAN node: a device plugin rations GPUs
  # between competing pods, and with nvidia as the default runtime the GPU is
  # injected into every container regardless.
  if [ "${INSTALL_DEVICE_PLUGIN:-0}" = 1 ]; then
    kubectl get ds -n kube-system nvidia-device-plugin-daemonset >/dev/null 2>&1 \
      || kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml
  else
    echo "   device plugin not installed (INSTALL_DEVICE_PLUGIN=1 to force)."
    echo "   Pods reach the GPU through the runtime; the chart does not request"
    echo "   nvidia.com/gpu unless you set l1.requestGpu=true."
    if kubectl get ds -n kube-system nvidia-device-plugin-daemonset >/dev/null 2>&1; then
      echo "   NOTE: a device-plugin DaemonSet is already present. On GB10 it will"
      echo "   crash-loop. Remove it with:"
      echo "     kubectl delete ds -n kube-system nvidia-device-plugin-daemonset"
    fi
  fi
else
  cat <<'MSG'
   Docker's default runtime is NOT nvidia, so pods cannot get the GPU and
   the device plugin has nothing to enumerate. Run these YOURSELF -- the
   restart interrupts every container on the host:

       sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null
       sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
       sudo systemctl restart docker

   Use nvidia-ctk rather than writing daemon.json by hand: it merges the
   runtime in and preserves any other settings the file already holds.

   Then re-run this script to install the device plugin.
MSG
fi

# ------------------------------------------------- kubepods CPU access
# The L1 pins its own threads to absolute core ids (workers_ul, workers_dl,
# dpdk_thread, data_core...). Those calls fail with EINVAL unless the pod's
# cgroup permits those cores, and the failure surfaces deep inside the
# fronthaul library as "Error setting CPU affinity mask: Invalid argument".
#
# A host that previously ran the L1 OUTSIDE Kubernetes may deliberately fence
# kubepods away from the RAN cores. That is right for that layout and wrong for
# this one: here the L1 IS a pod. Excluding those cores is also redundant, since
# isolcpus already stops the scheduler placing ordinary threads there -- only an
# explicit sched_setaffinity lands on them, which is exactly what Aerial does.
step_cpus() { printf '\n>> kubepods CPU access\n'; }
step_cpus
NPROC_ALL="$(nproc --all 2>/dev/null || nproc)"
WANT_CPUS="${KUBEPODS_CPUS:-0-$((NPROC_ALL - 1))}"
EFF="$(cat /sys/fs/cgroup/kubepods.slice/cpuset.cpus.effective 2>/dev/null)"
if [ -z "$EFF" ]; then
  echo "   could not read kubepods.slice cpuset (nothing to do, or cgroup v1)"
elif [ "$EFF" = "$WANT_CPUS" ]; then
  echo "   OK: kubepods may use $EFF"
else
  echo "   kubepods is restricted to '$EFF' but the L1 needs '$WANT_CPUS'"
  # A watchdog unit that re-applies the restriction will undo us every few
  # seconds, so it has to go first.
  # ONLY .service units, and only ones whose name is about cpus/cores.
  # kubepods.slice and its children ARE THE CGROUPS THE PODS LIVE IN --
  # matching them here and stopping them kills every pod on the node and
  # takes the kubelet's cgroup hierarchy with it.
  for u in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
             | awk '{print $1}' | grep -iE '\.service$' \
             | grep -iE '(kubepod|ran).*(cpu|core)'); do
    echo "   disabling watchdog service: $u"
    sudo systemctl disable --now "$u" >/dev/null 2>&1
  done
  sudo systemctl set-property --runtime kubepods.slice "AllowedCPUs=$WANT_CPUS" \
    && echo "   kubepods.slice AllowedCPUs=$WANT_CPUS" \
    || echo "   FAILED to widen kubepods cpuset"
  sleep 2
  echo "   now: $(cat /sys/fs/cgroup/kubepods.slice/cpuset.cpus.effective 2>/dev/null)"
  echo "   (runtime-only; re-run this script after a reboot)"
fi

echo
echo ">> node resources visible to the scheduler:"
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range $k,$v := .status.allocatable}{"   "}{$k}{"="}{$v}{"\n"}{end}{end}' 2>/dev/null \
  | grep -E 'cpu|memory|hugepages|nvidia' || echo "   (node not ready yet)"
echo
echo ">> next: ./scripts/4-render.sh"
