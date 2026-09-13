#!/usr/bin/env bash
# Check that this host is ready to run Aerial L1. READ-ONLY: it changes nothing.
#
#   ./scripts/1-preflight.sh
#
# Host preparation (driver, kernel, DOCA/OFED, hugepages, CPU isolation, NIC
# firmware, PTP) is deliberately OUT of scope for this repo -- it is done once
# per box, usually by whoever racked it, following NVIDIA's DGX Spark install
# guide. This script only tells you whether that work is present and correct,
# so a later failure in the RAN can be blamed on the RAN and not the host.
#
# Exit: 0 all good, 1 something FAILED.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/config/versions.env" ] && . "$ROOT/config/versions.env"

pass=0; warnc=0; failc=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warnc=$((warnc+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; failc=$((failc+1)); }
sec()  { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# cmp_ver <label> <found> <expected>  — exact match expected, near-match warns
cmp_ver() {
  if [ -z "$2" ];        then bad  "$1: not detected (expected $3)"
  elif [ "$2" = "$3" ];  then ok   "$1: $2"
  else                        warn "$1: $2 (validated: $3)"
  fi
}

sec "Platform"
ARCH="$(uname -m)"; cmp_ver "arch" "$ARCH" "$REQ_ARCH"
cmp_ver "kernel" "$(uname -r)" "$REQ_KERNEL"

sec "GPU"
if have nvidia-smi; then
  cmp_ver "driver" "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" "$REQ_DRIVER"
  GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  [ -n "$GPU" ] && ok "gpu: $GPU" || bad "no GPU reported"
  CU="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: *[0-9.]+' | grep -oE '[0-9.]+' | head -1)"
  cmp_ver "cuda" "$CU" "$REQ_CUDA"
else
  bad "nvidia-smi not found"
fi

sec "CUDA MPS (required: cuPHY partitions SMs across PUSCH/PDSCH/... via MPS)"
# GB10 has no MIG, so MPS is the only way to share the GPU with a dApp.
if pgrep -af nvidia-cuda-mps-control >/dev/null 2>&1; then
  ok "mps-control running"
else
  warn "MPS not running — start it before launching L1 (nvidia-cuda-mps-control -d)"
fi

sec "Memory / hugepages"
HP_SZ="$(grep -i '^Hugepagesize' /proc/meminfo | awk '{print $2}')"
HP_N="$(grep -i '^HugePages_Total' /proc/meminfo | awk '{print $2}')"
# 1G pages are the DGX Spark layout. A 64k-page ARM kernel (GH200's
# -64k kernel) has no 1G hugetlb size at all -- its sizes are 2M, 512M and
# 16G -- so 512M is the correct choice there, not a misconfiguration. Report
# the real size and the resulting total; the chart's hugepages.size must
# match whichever this is (config/values.yaml).
HP_MB=$(( ${HP_SZ:-0} / 1024 ))
case "$HP_MB" in
  1024) ok "hugepage size: 1G" ;;
  512)  ok "hugepage size: 512M (64k-page kernel; set hugepages.size=512Mi in config/values.yaml)" ;;
  *)    warn "hugepage size: ${HP_SZ:-none} kB (expected 1G, or 512M on a 64k-page kernel)" ;;
esac
HP_TOTAL_GB=$(( ${HP_N:-0} * HP_MB / 1024 ))
if [ "$HP_TOTAL_GB" -ge "$REQ_HUGEPAGES_1G" ] 2>/dev/null; then ok "hugepages: $HP_N x ${HP_MB}M = ${HP_TOTAL_GB}G"
else bad "hugepages: ${HP_N:-0} x ${HP_MB}M = ${HP_TOTAL_GB}G (expected >= ${REQ_HUGEPAGES_1G}G)"; fi

sec "CPU isolation"
CMD="$(cat /proc/cmdline)"
for k in isolcpus nohz_full rcu_nocbs; do
  v="$(printf '%s\n' "$CMD" | grep -oE "${k}=[^ ]+" || true)"
  if [ -n "$v" ]; then ok "$v"; else bad "$k missing from kernel cmdline (expected $k=...$REQ_ISOLCPUS)"; fi
done
# Deep cpuidle states add 40-450 us of wakeup latency to the L2 adapter's
# timer thread, which must wake within 15 us of the slot boundary or every
# slot errors out (0x34) and the DU transmits nothing. x86 recipes disable
# them with idle=poll / processor.max_cstate=0 -- both of which ARM SILENTLY
# IGNORES, so check the sysfs truth, not the cmdline. Fix (runtime, or wrap
# in a boot-time systemd unit):
#   for c in /sys/devices/system/cpu/cpu{4..19}/cpuidle/state*; do
#     [ "$(cat $c/latency)" -gt 10 ] && echo 1 | sudo tee $c/disable; done
DEEP_ON=0
for st in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
  [ -f "$st/latency" ] || continue
  cpu="${st#/sys/devices/system/cpu/cpu}"; cpu="${cpu%%/*}"
  case ",$(echo "$REQ_ISOLCPUS" | tr '-' ',')," in *",$cpu,"*) :;; *)
    # only isolated cores matter; expand the a-b range crudely
    lo="${REQ_ISOLCPUS%-*}"; hi="${REQ_ISOLCPUS#*-}"
    { [ "$cpu" -ge "$lo" ] && [ "$cpu" -le "$hi" ]; } 2>/dev/null || continue;;
  esac
  if [ "$(cat "$st/latency")" -gt 10 ] && [ "$(cat "$st/disable" 2>/dev/null)" = 0 ]; then
    DEEP_ON=$((DEEP_ON+1))
  fi
done
if [ "$DEEP_ON" -gt 0 ]; then
  bad "cpuidle: $DEEP_ON deep idle states ENABLED on isolated cores (>10 us exit latency) — timer ticks will miss the 15 us budget"
else
  ok "cpuidle: no deep idle states enabled on isolated cores"
fi

sec "PTP timescale consistency"
# Aerial computes GPS frame numbering as CLOCK_REALTIME + kernel-TAI-offset;
# the RU treats the PTP wire time as TAI directly. These must agree. With
# phc2sys -O 0 the wire carries whatever timescale CLOCK_REALTIME has, so a
# kernel TAI offset of 37 makes the DU number frames 37 s (= 116 frameIds)
# away from the RU: the RU classifies 100% of C-plane as EARLY and discards
# it. The cell starts, transmits, and stays stone dead. Consistent pairs:
#   wire=TAI  (phc2sys -O -37 or -w, PHC stepped +37)  + kernel TAI 37
#   wire=UTC  (phc2sys -O 0)                           + kernel TAI 0
KTAI="$(python3 -c 'import time;print(int(round(time.clock_gettime(11)-time.time())))' 2>/dev/null)"
P2S="$(pgrep -af '[p]hc2sys' | head -1)"
if [ -z "$P2S" ]; then
  warn "phc2sys not running — cannot judge the wire timescale"
elif printf '%s' "$P2S" | grep -qE '(-O *0([^0-9-]|$))'; then
  if [ "${KTAI:-0}" -eq 0 ]; then ok "wire=UTC (-O 0) and kernel TAI offset 0 — consistent"
  else bad "phc2sys -O 0 puts CLOCK_REALTIME's timescale on the wire, but kernel TAI offset is ${KTAI}s — the DU will number frames ${KTAI}s away from the RU (all C-plane classified EARLY). Either zero the kernel TAI offset, or step the PHC to TAI and use phc2sys -O -37"; fi
elif printf '%s' "$P2S" | grep -qE '(-O *-37|-w)'; then
  if [ "${KTAI:-0}" -eq 37 ]; then ok "wire=TAI (phc2sys ${KTAI:+-O -37/-w}) and kernel TAI offset 37 — consistent"
  else bad "phc2sys implies a TAI wire but kernel TAI offset is ${KTAI:-unknown}s (expected 37)"; fi
else
  warn "phc2sys offset mode unrecognized ($P2S) — verify wire timescale vs kernel TAI offset (${KTAI:-unknown}s) manually"
fi
# nproc honours the caller's CPU affinity, and isolcpus removes the isolated
# cores from the default scheduler domain -- so on a correctly isolated host a
# plain `nproc` reports only the housekeeping cores. Report both, or "cores: 4"
# on a 20-core box reads like a fault when it is proof the isolation works.
NPROC_ALL="$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
NPROC_AVAIL="$(nproc)"
if [ "${NPROC_AVAIL:-0}" -lt "${NPROC_ALL:-0}" ] 2>/dev/null; then
  ok "cores: $NPROC_ALL total, $NPROC_AVAIL unisolated (isolation is active)"
else
  ok "cores: $NPROC_ALL total (no CPU isolation in effect)"
fi

sec "Fronthaul NIC"
FH=""
for i in $(ls /sys/class/net 2>/dev/null | grep -v lo); do
  drv="$(ethtool -i "$i" 2>/dev/null | awk '/^driver:/{print $2}')"
  [ "$drv" = "mlx5_core" ] || continue
  mtu="$(cat "/sys/class/net/$i/mtu" 2>/dev/null)"
  link="$(cat "/sys/class/net/$i/operstate" 2>/dev/null)"
  fw="$(ethtool -i "$i" 2>/dev/null | awk '/^version:/{print $2}')"
  if [ "$link" = "up" ] && [ "${mtu:-0}" -ge "$REQ_FH_MTU" ] 2>/dev/null; then
    ok "$i: link up, mtu $mtu, ofed $fw  <- fronthaul candidate"
    FH="$i"
  else
    printf '  ....  %s: link %s, mtu %s\n' "$i" "${link:-?}" "${mtu:-?}"
  fi
  [ -n "$fw" ] && [ "$fw" != "$REQ_OFED" ] && warn "$i ofed $fw (validated: $REQ_OFED)"
done
[ -n "$FH" ] || bad "no mlx5 port that is up with MTU >= $REQ_FH_MTU (fronthaul needs jumbo frames)"

# NIC FIRMWARE, not driver settings. Without the flex parser the NIC cannot
# classify eCPRI, and the L1 logs "eCPRI parser not supported ... retrying
# without eCPRI" -- it keeps running, so this fails as degraded fronthaul
# rather than as an error. These live in firmware and need mlxfwreset or a
# power cycle to take effect.
if command -v mlxconfig >/dev/null 2>&1; then
  BDF="$(ethtool -i "${FH:-none}" 2>/dev/null | awk '/bus-info:/{print $2}')"
  if [ -n "$BDF" ]; then
    MC="$(sudo mlxconfig -d "$BDF" q 2>/dev/null)"
    for kv in FLEX_PARSER_PROFILE_ENABLE:4 PROG_PARSE_GRAPH:True \
              REAL_TIME_CLOCK_ENABLE:True ACCURATE_TX_SCHEDULER:True CQE_COMPRESSION:AGGRESSIVE; do
      k="${kv%%:*}"; want="${kv##*:}"
      got="$(printf '%s\n' "$MC" | awk -v k="$k" '$1==k{print $2}')"
      if [ -z "$got" ]; then info "$k: not reported"
      elif printf '%s' "$got" | grep -qi "$want"; then ok "$k = $got"
      else bad "$k = $got (expected $want) — eCPRI/flow steering will not work"
      fi
    done
  fi
else
  info "mlxconfig not installed — cannot verify NIC firmware (flex parser, eCPRI)"
fi

sec "PTP (fronthaul is time-synchronous; without lock the RU will not accept U-plane)"
if pgrep -af '[p]tp4l' >/dev/null 2>&1; then
  ok "ptp4l running"
  RMS="$(journalctl -u ptp4l --no-pager -n 20 2>/dev/null | grep -oE 'rms +[0-9]+' | tail -1 | awk '{print $2}')"
  if [ -n "$RMS" ]; then
    if [ "$RMS" -lt 100 ] 2>/dev/null; then ok "ptp4l rms ${RMS} ns (locked)"
    else warn "ptp4l rms ${RMS} ns — high; expect fronthaul errors above ~100 ns"; fi
  fi
else
  bad "ptp4l not running"
fi
pgrep -af '[p]hc2sys' >/dev/null 2>&1 && ok "phc2sys running" || warn "phc2sys not running"

sec "Container runtime"
if have docker && docker info >/dev/null 2>&1; then
  ok "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if docker info 2>/dev/null | grep -qi 'nvidia'; then ok "nvidia container runtime present"
  else warn "nvidia runtime not visible in docker info (needed to give L1 the GPU)"; fi
else
  bad "docker not usable by this user"
fi
# The Aerial image pulls anonymously; what matters is reaching the registry.
if curl -sfI --max-time 8 https://nvcr.io/v2/ >/dev/null 2>&1 \
   || curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://nvcr.io/v2/ 2>/dev/null | grep -qE '200|401'; then
  ok "nvcr.io reachable (the Aerial image pulls without a login)"
else
  warn "cannot reach nvcr.io — needed only if the Aerial image is not already local"
fi

sec "Disk"
FREE_GB="$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')"
[ -z "$FREE_GB" ] && FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "${FREE_GB:-0}" -ge "$REQ_FREE_GB" ] 2>/dev/null; then ok "free: ${FREE_GB}G"
else bad "free: ${FREE_GB:-?}G — need >= ${REQ_FREE_GB}G (the Aerial image alone is ~26 GB)"; fi

printf '\n== Summary ==\n  %d passed, %d warnings, %d failures\n' "$pass" "$warnc" "$failc"
if [ "$failc" -gt 0 ]; then
  echo "  Host is NOT ready. Fix the FAIL items (see NVIDIA's DGX Spark install guide)."
  exit 1
fi
echo "  Host looks ready for the Aerial stack."
