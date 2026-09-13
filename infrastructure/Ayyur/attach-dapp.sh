#!/usr/bin/env bash
# Attach the Ayyur dApp to a running V-RAN deployment.
#
# Run this ON THE DU-LOW HOST. The dApp reads uplink CSI from the L1 over E3,
# which is a shared-memory segment (/e3_ran_buffers) plus localhost TCP -- it
# cannot be done from another machine. The reports it produces travel onward to
# the RIC through the DU-High's E2 agent, which does cross the network.
#
#   ./attach-dapp.sh status     what is attached right now
#   ./attach-dapp.sh attach     start the dApp and the cascade
#   ./attach-dapp.sh detach     stop them
#
# WHY THE CELL MUST BE IDLE
#
# The cascade shares one GB10 with the L1. There is no MIG on this part, so the
# only isolation is CUDA MPS, and creating an MPS client context makes the
# server reprovision -- tens of milliseconds during which all GPU work stalls.
# With a UE on the cell that is not a late slot, it is fatal: every cuPHY
# watchdog trips at once and the L1 aborts. Attaching while the cell is idle is
# harmless. This script refuses to attach when it sees a UE.
#
# Steady-state cost once attached, measured: ~26 late slots/min against a
# baseline of 0, with the cascade capped to 12 of 48 SMs at below-normal
# priority. Uplink holds. Without the cap it is 50-100 and the uplink collapses.
set -uo pipefail

NS="${NAMESPACE:-ran}"
AYYUR_DIR="${AYYUR_DIR:-$HOME/ayyur}"
SM_PCT="${AYYUR_MPS_PCT:-25}"        # CUDA_MPS_ACTIVE_THREAD_PERCENTAGE
SM_PRIO="${AYYUR_MPS_PRIO:-1}"       # 0 normal, 1 below normal
FORWARD_PORT="${AYYUR_FORWARD_PORT:-5570}"
E3_CONFIG="${AYYUR_E3_CONFIG:-config/e3_config.json}"   # site variants: set AYYUR_E3_CONFIG

die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m%s\033[0m\n' "$*"; }
warn() { printf '   \033[33m%s\033[0m\n' "$*"; }

l1_pid() { pgrep -x cuphycontroller_scf | head -1; }

# The MPS control daemon and server run INSIDE the L1 container. A host process
# that does not use that pipe directory is not an MPS client at all: it gets a
# plain context the GPU time-slices against the L1, the worst way to share, and
# the SM cap is silently ignored. Reach the container's directory through /proc.
mps_pipe_dir() {
  local p; p="$(l1_pid)"
  if [ -n "$p" ] && sudo test -S "/proc/$p/root/tmp/nvidia-mps/control" 2>/dev/null; then
    echo "/proc/$p/root/tmp/nvidia-mps"
  else
    echo /tmp/nvidia-mps
  fi
}

cmd_status() {
  step "V-RAN"
  kubectl get pods -n "$NS" --no-headers 2>/dev/null \
    | awk '{printf "   %-32s %-6s %s\n", $1,$2,$3}' || warn "no cluster"

  step "E3 (L1 -> dApp)"
  [ -e /dev/shm/e3_ran_buffers ] \
    && ok "shm /e3_ran_buffers present ($(stat -c %s /dev/shm/e3_ran_buffers) bytes)" \
    || warn "shm /e3_ran_buffers ABSENT -- the L1 has not created it"
  pgrep -f ayyur_dapp >/dev/null && ok "ayyur_dapp running" || warn "ayyur_dapp not running"

  step "Cascade"
  if pgrep -f "ayyur.cascade.main" >/dev/null; then
    ok "cascade running"
    nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv,noheader 2>/dev/null \
      | grep -i python | sed 's/^/   GPU: /'
  else
    warn "cascade not running"
  fi

  step "Bridge to the E2 agent (dApp binds, agent connects in)"
  ss -tn 2>/dev/null | grep -E ':600[12]' | awk '{print "   "$4"  <-  "$5}' | sort -u \
    || warn "nothing connected to :6001/:6002"

  # These lines are printed once at startup and the log grows quickly with
  # per-frame output, so a short tail will miss them.
  step "E2 agent"
  local e2; e2="$(kubectl logs -n "$NS" deploy/oai-du-high --tail=20000 2>/dev/null \
    | grep -iE 'E2SM-AYYUR|libayyur_sm|E2 SETUP RESPONSE' | tail -3)"
  if [ -n "$e2" ]; then echo "$e2" | sed 's/^/   /'
  else warn "no E2SM-AYYUR lines found -- is the DU-High running the Ayyur build?"; fi
}

cell_has_ue() {
  kubectl logs -n "$NS" deploy/oai-du-high --since=20s 2>/dev/null \
    | grep -cE 'UE RNTI|in-sync' 2>/dev/null || echo 0
}

cmd_attach() {
  command -v kubectl >/dev/null || die "kubectl not found"
  [ -d "$AYYUR_DIR" ] || die "AYYUR_DIR=$AYYUR_DIR does not exist"

  step "Preconditions"
  [ -n "$(l1_pid)" ] || die "the L1 (cuphycontroller_scf) is not running on this host"
  ok "L1 running, pid $(l1_pid)"
  [ -e /dev/shm/e3_ran_buffers ] || die "no /e3_ran_buffers -- the L1 has not published its E3 segment"
  ok "E3 shared memory present"

  # Rule 1 from docs/GPU_SHARING_ZION.md. Attaching under traffic killed the L1
  # twice; attaching while idle was harmless both times.
  local ue; ue="$(cell_has_ue)"
  if [ "${ue:-0}" -gt 0 ]; then
    die "a UE appears to be on the cell ($ue recent RNTI/in-sync lines).
       Attaching an MPS client now can kill the L1 outright, not merely cause
       late slots. Wait for the cell to be idle, or detach the UE first."
  fi
  ok "cell is idle -- safe to attach"

  step "dApp (E3 ingest)"
  if pgrep -f ayyur_dapp >/dev/null; then
    ok "already running"
  else
    ( cd "$AYYUR_DIR/cpp/ayyur_dapp" && \
      setsid nohup ./build/bin/ayyur_dapp --config "$E3_CONFIG" \
        --forward-port "$FORWARD_PORT" --control-port 0 --latent-port 0 \
        > "$AYYUR_DIR/logs/ayyur_dapp.log" 2>&1 < /dev/null & )
    sleep 3
    pgrep -f ayyur_dapp >/dev/null && ok "started" || die "failed to start -- see logs/ayyur_dapp.log"
  fi

  step "Cascade (MPS client, ${SM_PCT}% SM cap, priority $SM_PRIO)"
  local pipe; pipe="$(mps_pipe_dir)"
  echo "   MPS pipe: $pipe"
  [ "$pipe" = /tmp/nvidia-mps ] && warn "not the L1 container's pipe dir -- the SM cap will be IGNORED"
  sudo env CUDA_MPS_PIPE_DIRECTORY="$pipe" \
           CUDA_MPS_ACTIVE_THREAD_PERCENTAGE="$SM_PCT" \
           CUDA_MPS_CLIENT_PRIORITY="$SM_PRIO" \
    setsid nohup "$AYYUR_DIR/.venv/bin/python" -m ayyur.cascade.main \
      --from-dapp "tcp://127.0.0.1:$FORWARD_PORT" \
      > "$AYYUR_DIR/logs/ayyur_cascade.log" 2>&1 < /dev/null &
  sleep 5
  pgrep -f "ayyur.cascade.main" >/dev/null && ok "started" || die "failed -- see logs/ayyur_cascade.log"

  step "Result"
  cmd_status
  cat <<'MSG'

   Watch the cost:  kubectl logs -n ran deploy/aerial-cubb -c nv-cubb -f | grep -E 'Cell  0 \||Late slot'
   Baseline is 0 late slots; ~26/min is the accepted level with the cascade attached.
MSG
}

cmd_detach() {
  # Stopping the cascade under traffic is untested and plausibly fatal for the
  # same reason attaching is. The safe order is: stop the L2, stop the cascade,
  # start the L2 again -- the L1 and its E3 clients survive that.
  step "Detach"
  local ue; ue="$(cell_has_ue)"
  [ "${ue:-0}" -gt 0 ] && warn "a UE looks active -- stopping the cascade now is untested and may abort the L1"
  for pat in "ayyur.cascade.main" "ayyur_dapp"; do
    if pgrep -f "$pat" >/dev/null; then
      sudo pkill -f "$pat" && ok "stopped $pat"
    else
      warn "$pat not running"
    fi
  done
}

case "${1:-status}" in
  status) cmd_status ;;
  attach) cmd_attach ;;
  detach) cmd_detach ;;
  *) echo "usage: $0 {status|attach|detach}" >&2; exit 2 ;;
esac
