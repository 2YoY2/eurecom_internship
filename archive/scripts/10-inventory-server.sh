#!/usr/bin/env bash
# Phase 0 for an ALREADY-DEPLOYED server: capture everything needed to rebuild
# the Aerial + RAN stack before you tear anything down.
#
# READ-ONLY. It starts/stops/deletes nothing. Run it as a user in the docker
# group; some sections want sudo (it degrades gracefully without it).
#
#   ./10-inventory-server.sh            # writes ~/aerial-inventory-<host>-<date>/
#   SUDO=1 ./10-inventory-server.sh     # same, but uses sudo for privileged reads
set -uo pipefail   # NOT -e: a missing tool must never abort the sweep

OUT="${OUT:-$HOME/aerial-inventory-$(hostname -s)-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"/{host,gpu,net,ptp,docker,k8s,aerial,ru}
S=""; [ "${SUDO:-0}" = 1 ] && S="sudo"

have() { command -v "$1" >/dev/null 2>&1; }
# run <file> <cmd...>  → append a labelled command's output to a section file
run() { local f="$1"; shift; { echo "### \$ $*"; "$@" 2>&1; echo; } >>"$f"; }

echo ">> writing to $OUT"

# ---------------------------------------------------------------- host
H="$OUT/host/host.txt"
run "$H" uname -a
run "$H" cat /etc/os-release
run "$H" lscpu
run "$H" cat /proc/cmdline          # isolcpus / hugepages / iommu — Aerial needs these
run "$H" free -g
run "$H" df -h
run "$H" cat /proc/meminfo
grep -i huge /proc/meminfo > "$OUT/host/hugepages.txt" 2>&1
have tuned-adm && run "$H" tuned-adm active
run "$H" uptime
$S systemctl list-units --type=service --state=running --no-pager > "$OUT/host/services-running.txt" 2>&1
$S systemctl list-unit-files --state=enabled --no-pager    > "$OUT/host/services-enabled.txt" 2>&1
ps -eo pid,ppid,user,etime,pcpu,pmem,args --sort=-pcpu | head -60 > "$OUT/host/processes.txt" 2>&1
# the processes that matter, with their full command lines and open files
for p in cuphycontroller nr-softmodem nr-uesoftmodem ru-emulator mps ptp4l phc2sys testmac; do
  pgrep -a "$p" >> "$OUT/host/processes-of-interest.txt" 2>&1
done

# ---------------------------------------------------------------- gpu / cuda
G="$OUT/gpu/gpu.txt"
have nvidia-smi && { run "$G" nvidia-smi; run "$G" nvidia-smi -q; run "$G" nvidia-smi topo -m; }
have nvidia-smi && nvidia-smi -q -x > "$OUT/gpu/nvidia-smi.xml" 2>&1
# Only CUDA/MPS/Aerial vars. NEVER dump the whole environment: it routinely
# holds NGC_API_KEY / registry tokens, and this output gets shared.
{ echo "### \$ env (filtered)"
  env | grep -E '^(CUDA|NVIDIA|MPS|AERIAL|CUBB|NVIPC)' \
      | grep -viE 'key|token|secret|password|passwd|auth'
  echo; } >> "$G" 2>&1
$S ls -l /tmp/nvidia-mps /var/log/nvidia-mps > "$OUT/gpu/mps.txt" 2>&1
lsmod | grep -iE 'nvidia|nvme|gdrdrv|peermem|mlx|ib_' > "$OUT/gpu/modules.txt" 2>&1
have nvcc && run "$G" nvcc --version
have dpkg && dpkg -l | grep -iE 'cuda|nvidia|doca|ofed|rshim|aerial' > "$OUT/gpu/packages.txt" 2>&1

# ---------------------------------------------------------------- network / fronthaul
N="$OUT/net/net.txt"
run "$N" ip -br a
run "$N" ip -d link show          # -d reveals VLANs, VFs, bonds
run "$N" ip route
run "$N" ip -br link
$S lspci -nnvv 2>/dev/null | grep -iEA8 'mellanox|connectx|bluefield|ethernet' > "$OUT/net/lspci.txt" 2>&1
have ofed_info && ofed_info -s > "$OUT/net/ofed.txt" 2>&1
have mst && { $S mst status -v > "$OUT/net/mst.txt" 2>&1; }
# per-NIC detail: driver, bus id, SR-IOV VFs, ring/flow settings
for i in $(ls /sys/class/net | grep -v lo); do
  {
    echo "=== $i ==="
    ethtool -i "$i" 2>&1
    echo "-- numvfs:"; cat "/sys/class/net/$i/device/sriov_numvfs" 2>/dev/null
    echo "-- mac:";    cat "/sys/class/net/$i/address" 2>/dev/null
    echo "-- mtu:";    cat "/sys/class/net/$i/mtu" 2>/dev/null
    ethtool "$i" 2>&1 | grep -iE 'speed|link detected'
    echo
  } >> "$OUT/net/interfaces.txt" 2>&1
done
have mlxconfig && for d in $(ls /dev/mst 2>/dev/null); do
  $S mlxconfig -d "/dev/mst/$d" q >> "$OUT/net/mlxconfig.txt" 2>&1
done
$S cat /etc/netplan/*.yaml > "$OUT/net/netplan.txt" 2>&1
$S iptables-save > "$OUT/net/iptables.txt" 2>&1

# ---------------------------------------------------------------- PTP (fronthaul timing)
P="$OUT/ptp/ptp.txt"
for u in ptp4l phc2sys ts2phc chronyd systemd-timesyncd; do
  { echo "=== $u ==="; $S systemctl status "$u" --no-pager -l 2>&1 | head -30; } >> "$P"
done
$S cp -r /etc/linuxptp "$OUT/ptp/" 2>/dev/null
$S cp /etc/ptp4l.conf /etc/phc2sys.conf "$OUT/ptp/" 2>/dev/null
$S cp /etc/sysconfig/{ptp4l,phc2sys} "$OUT/ptp/" 2>/dev/null
$S cp /lib/systemd/system/{ptp4l,phc2sys,ts2phc}*.service "$OUT/ptp/" 2>/dev/null
$S cp /etc/systemd/system/{ptp4l,phc2sys,ts2phc}*.service "$OUT/ptp/" 2>/dev/null
# live sync state: are we locked to the grandmaster?
have pmc && $S pmc -u -b 0 'GET TIME_STATUS_NP' >> "$P" 2>&1
have pmc && $S pmc -u -b 0 'GET PARENT_DATA_SET' >> "$P" 2>&1
have pmc && $S pmc -u -b 0 'GET CURRENT_DATA_SET' >> "$P" 2>&1
$S journalctl -u ptp4l -u phc2sys --no-pager -n 100 > "$OUT/ptp/journal.txt" 2>&1

# ---------------------------------------------------------------- docker  (the important one)
D="$OUT/docker"
have docker || echo "docker not installed" > "$D/none.txt"
if have docker; then
  docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}\t{{.Ports}}' > "$D/ps.txt" 2>&1
  docker images --digests > "$D/images.txt" 2>&1
  docker volume ls  > "$D/volumes.txt" 2>&1
  docker network ls > "$D/networks.txt" 2>&1
  $S cat /etc/docker/daemon.json > "$D/daemon.json" 2>&1
  # FULL inspect = mounts, env, devices, caps, netmode, entrypoint. This is what
  # lets you recreate a container you no longer have.
  docker inspect $(docker ps -aq) > "$D/inspect-all.json" 2>&1
  for c in $(docker ps -a --format '{{.Names}}'); do
    docker inspect "$c" > "$D/inspect-$c.json" 2>&1
    docker logs --tail 300 "$c" > "$D/logs-$c.txt" 2>&1
    # the run-command equivalent, human readable
    { echo "=== $c ==="
      docker inspect "$c" --format '
image:      {{.Config.Image}}
cmd:        {{.Config.Cmd}}
entrypoint: {{.Config.Entrypoint}}
network:    {{.HostConfig.NetworkMode}}
privileged: {{.HostConfig.Privileged}}
mounts:     {{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}) ; {{end}}
devices:    {{range .HostConfig.Devices}}{{.PathOnHost}} ; {{end}}
env:        {{range .Config.Env}}{{.}} ; {{end}}'
      echo; } >> "$D/summary.txt" 2>&1
  done
  docker network inspect $(docker network ls -q) > "$D/networks.json" 2>&1
fi
# any compose files lying around define the whole deployment
find / -xdev \( -name 'docker-compose*.y*ml' -o -name 'compose.y*ml' \) 2>/dev/null \
  | grep -viE '/(var/lib/docker|snap|proc)/' | head -50 > "$D/compose-files-found.txt"
while read -r f; do
  [ -n "$f" ] && { echo "=== $f ==="; cat "$f"; echo; } >> "$D/compose-files-content.txt" 2>&1
done < "$D/compose-files-found.txt"

# ---------------------------------------------------------------- kubernetes
K="$OUT/k8s"
for b in kubectl helm k3s minikube kubeadm kubelet crictl; do
  have "$b" && echo "$b: $(command -v $b)" >> "$K/tools.txt"
done
if have kubectl; then
  kubectl cluster-info            > "$K/cluster-info.txt" 2>&1
  kubectl get nodes -o wide       > "$K/nodes.txt" 2>&1
  kubectl get all -A -o wide      > "$K/all.txt" 2>&1
  kubectl get pods -A -o yaml     > "$K/pods.yaml" 2>&1
  kubectl get ns                  > "$K/namespaces.txt" 2>&1
  kubectl get cm,secret -A        > "$K/configmaps-secrets.txt" 2>&1   # names only, no values
  kubectl get pv,pvc -A           > "$K/storage.txt" 2>&1
  kubectl get crd                 > "$K/crds.txt" 2>&1
  kubectl get node -o yaml        > "$K/node-detail.yaml" 2>&1          # allocatable: hugepages, sriov, gpu
fi
have helm && { helm list -A > "$K/helm-list.txt" 2>&1
  for r in $(helm list -A -q 2>/dev/null); do
    ns=$(helm list -A -f "^$r\$" -o json 2>/dev/null | grep -o '"namespace":"[^"]*"' | cut -d'"' -f4)
    helm get values "$r" -n "$ns" -a > "$K/values-$r.yaml" 2>&1
    helm get manifest "$r" -n "$ns"  > "$K/manifest-$r.yaml" 2>&1
  done; }
$S cp -r /etc/cni/net.d      "$K/cni"          2>/dev/null
$S cp -r /etc/rancher        "$K/rancher"      2>/dev/null
$S cp -r /etc/kubernetes     "$K/kubernetes"   2>/dev/null
$S ls -l /var/lib/kubelet /var/lib/rancher /var/lib/etcd > "$K/state-dirs.txt" 2>&1
have crictl && $S crictl ps -a > "$K/crictl-ps.txt" 2>&1

# ---------------------------------------------------------------- Aerial / RAN config
# THIS is the part that is painful to recreate: cell config, fronthaul MACs,
# eAxC ids, PCIe addresses, L2/L3 config.
A="$OUT/aerial"
find / -xdev -maxdepth 7 \( \
     -iname 'cuphycontroller*.yaml' -o -iname 'l2_config*.yaml' -o -iname 'ru-emulator*.yaml' \
  -o -iname 'nrSim*.yaml' -o -iname 'cubb*.yaml' -o -iname 'aerial*.yaml' \
  -o -iname 'gnb*.conf'   -o -iname '*.band*.conf'  -o -iname 'oai*.conf' \) \
  2>/dev/null | grep -viE '/(var/lib/docker|snap|proc|sys)/' | head -80 > "$A/config-files-found.txt"
while read -r f; do
  [ -n "$f" ] || continue
  d="$A/files/$(dirname "$f")"; mkdir -p "$d"; cp "$f" "$d/" 2>/dev/null
done < "$A/config-files-found.txt"
# well-known install locations
for p in /opt/nvidia /opt/cuBB "$HOME/cuBB" "$HOME/aerial" "$HOME/ARC" "$HOME/arc-ota" \
         /usr/local/aerial /opt/aerial /opt/oai /root/cuBB; do
  [ -e "$p" ] && { echo "=== $p ==="; $S ls -laR "$p" 2>/dev/null | head -200; echo; } >> "$A/install-dirs.txt"
done
# any git checkouts tell you exactly which release they built from
find / -xdev -maxdepth 6 -name '.git' -type d 2>/dev/null | grep -viE '/(var/lib/docker|snap)/' | head -30 \
  | while read -r g; do
      r="$(dirname "$g")"
      { echo "=== $r ==="
        git -C "$r" remote -v 2>&1
        git -C "$r" log -1 --oneline 2>&1
        git -C "$r" describe --tags --always 2>&1
        git -C "$r" status -s 2>&1 | head -20
        echo; } >> "$A/git-repos.txt"
    done

# ---------------------------------------------------------------- Benetel RU / M-plane
R="$OUT/ru"
run "$R/ru.txt" ip neigh          # the RU's IP will be in the ARP table
$S arp -an >> "$R/ru.txt" 2>&1
grep -rilE 'benetel|ran550|ran-550' /etc /opt "$HOME" 2>/dev/null | head -40 > "$R/benetel-references.txt"
while read -r f; do
  [ -f "$f" ] && { echo "=== $f ==="; head -100 "$f"; echo; } >> "$R/benetel-files.txt" 2>&1
done < "$R/benetel-references.txt"
# fronthaul MAC/VLAN/eAxC as configured on the L1 side.
# Guard the empty case: `grep -r` with no file operands would recurse the
# current directory instead, which is slow and captures the wrong thing.
if [ -s "$A/config-files-found.txt" ]; then
  xargs -r -d '\n' -a "$A/config-files-found.txt" \
    grep -hiE 'src_mac|dst_mac|vlan|eaxc|nic|pcie|cell_group|band|prach' 2>/dev/null \
    | head -200 > "$R/fronthaul-params.txt"
else
  echo "no Aerial config files found on the host filesystem" > "$R/fronthaul-params.txt"
  echo "(if the stack ran in containers, look in docker/inspect-*.json mounts)" >> "$R/fronthaul-params.txt"
fi
have netopeer2-cli && echo "netopeer2-cli present (M-plane NETCONF client)" >> "$R/ru.txt"

# ---------------------------------------------------------------- wrap up
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
{
  echo "host:      $(hostname) / $(uname -m) / $(. /etc/os-release; echo $PRETTY_NAME)"
  echo "kernel:    $(uname -r)"
  echo "gpu:       $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"
  echo "containers:$(docker ps -q 2>/dev/null | wc -l) running / $(docker ps -aq 2>/dev/null | wc -l) total"
  echo "images:    $(docker images -q 2>/dev/null | wc -l)"
  echo "k8s:       $(kubectl get nodes --no-headers 2>/dev/null | wc -l) node(s); helm releases: $(helm list -A -q 2>/dev/null | wc -l)"
  echo "aerial cfg:$(wc -l < "$A/config-files-found.txt") file(s) found"
} > "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
echo
echo ">> full inventory : $OUT"
echo ">> archive        : $OUT.tar.gz"
echo ">> nothing was stopped, changed or deleted."
