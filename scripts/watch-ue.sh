#!/usr/bin/env bash
# Watch a UE attach and localize WHERE the user plane breaks.
#
#   ./scripts/watch-ue.sh          # watch for 5 minutes (Ctrl-C to stop early)
#   ./scripts/watch-ue.sh 900      # watch for 15 minutes
#
# "The UE attaches but has no internet" has several very different causes that
# look identical from the UE. This runs all the observations at once, so one
# attach attempt tells you which one you have:
#
#   radio/RRC   -- gNB log: did the UE get through RA and RRC setup?
#   NGAP/NAS    -- gNB log: registration, initial context, PDU session setup
#   N3 GTP-U    -- tcpdump on 2152: is the tunnel carrying traffic, which way?
#
# It changes nothing. Everything lands in config/ue-capture-<timestamp>/ (config/
# is untracked) and a verdict is printed at the end.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="${NAMESPACE:-ran}"
SEL="app.kubernetes.io/name=aerial-du"
DUR="${1:-300}"
OUT="$ROOT/config/ue-capture-$(date +%Y%m%d-%H%M%S)"
SITE="$ROOT/config/site.yaml"

die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
step(){ printf '\n\033[1m>> %s\033[0m\n' "$*"; }

step "Preflight"
need_tool kubectl >/dev/null || die "kubectl unavailable"
command -v tcpdump >/dev/null 2>&1 || die "tcpdump not installed (sudo apt install -y tcpdump)"
kubectl get pods -n "$NS" -l "$SEL" >/dev/null 2>&1 || die "no DU pod in namespace $NS"
# Pick a pod that is Running and NOT terminating. Right after a deploy the old
# pod still exists in Terminating state and sorts first, so grabbing
# items[0] attaches the capture to a pod that is about to die -- the log stream
# ends immediately and the run reports "no UE reached the radio", which is a
# lie about a cluster that is simply mid-rollout.
# Query each pod's fields individually. The tempting one-liner --
#   -o jsonpath='{.items[?(@.metadata.deletionTimestamp=="")]...}'
# -- does NOT work: kubectl's filter expressions do not match a field that is
# ABSENT, so a healthy pod (which has no deletionTimestamp at all) is skipped
# and the loop waits forever. Asking for a single missing field, by contrast,
# reliably prints nothing.
POD=""
for i in $(seq 1 60); do
  for ref in $(kubectl get pods -n "$NS" -l "$SEL" -o name 2>/dev/null); do
    name="${ref#pod/}"
    del="$(kubectl get "$ref" -n "$NS" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)"
    ph="$(kubectl get "$ref" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [ -z "$del" ] && [ "$ph" = "Running" ]; then POD="$name"; break; fi
  done
  [ -n "$POD" ] && break
  [ "$i" = 1 ] && echo "   waiting for a Running (non-terminating) DU pod..."
  sleep 5
done
[ -n "$POD" ] || die "no Running DU pod appeared in namespace $NS after 5 minutes"
# Ready means the L1 printed "L1 is ready!" -- before that there is no cell for
# a UE to attach to, and capturing is pointless.
if ! kubectl wait --for=condition=ready "pod/$POD" -n "$NS" --timeout=600s >/dev/null 2>&1; then
  echo "   WARNING: $POD is Running but not Ready -- the L1 may still be initialising"
fi

# The gNB's own N3 address decides packet direction: src=N3 is uplink (gNB to
# UPF), dst=N3 is downlink. Prefer site.yaml; fall back to the pod IP, which is
# the host IP because the DU runs with hostNetwork.
N3=""
[ -f "$SITE" ] && command -v yq >/dev/null 2>&1 && N3="$(yq -r '.core.gnb_n2_ip // ""' "$SITE" 2>/dev/null)"
[ -n "$N3" ] && [ "$N3" != "null" ] || N3="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.podIP}')"
[ -n "$N3" ] || die "could not determine the gNB N3 address"
mkdir -p "$OUT"
echo "   pod       : $POD"
echo "   gNB N3    : $N3  (uplink = src, downlink = dst)"
echo "   capturing : ${DUR}s into $OUT"

PCAP="$OUT/n3-gtpu.pcap"; GNBLOG="$OUT/gnb.log"; L1LOG="$OUT/l1-events.log"
TD_PID=""; LOG_PID=""; DONE=0

finish() {
  [ "$DONE" = 1 ] && return; DONE=1
  [ -n "$TD_PID" ]  && sudo kill "$TD_PID"  2>/dev/null
  [ -n "$LOG_PID" ] && kill "$LOG_PID" 2>/dev/null
  sleep 1

  step "What the gNB saw"
  # Events in the order they must happen for a working data path.
  ev() { local n; n="$(grep -icE "$1" "$GNBLOG" 2>/dev/null)"; echo "${n:-0}"; }
  RA="$(ev 'msg3|ra-rnti|random access|rrcsetuprequest')"
  RRC="$(ev 'rrcsetupcomplete|rrc_setup_complete|msg4')"
  REG="$(ev 'initial ue message|initialuemessage|ngap_initial_ue')"
  CTX="$(ev 'initial context setup|initialcontextsetup')"
  PDU="$(ev 'pdusession.*setup|pdu session.*setup|pdusession_setup')"
  PDUFAIL="$(ev 'pdusession.*fail|pdu session.*fail|session.*reject|resource.*fail')"
  TEID="$(ev 'teid')"
  printf '  %-34s %s\n' "RA / RRCSetupRequest"        "$RA"
  printf '  %-34s %s\n' "RRC setup complete"          "$RRC"
  printf '  %-34s %s\n' "NGAP initial UE message"     "$REG"
  printf '  %-34s %s\n' "Initial context setup"       "$CTX"
  printf '  %-34s %s\n' "PDU session setup"           "$PDU"
  printf '  %-34s %s\n' "PDU session failure/reject"  "$PDUFAIL"
  printf '  %-34s %s\n' "GTP-U tunnel / TEID lines"   "$TEID"

  # Radio health. A session can exist on paper while the link underneath is
  # collapsing -- and then packet counts on N3 look encouraging and point the
  # investigation at the core, which is wrong.
  RLF="$(ev 'UL Failure on PUSCH')"
  REEST="$(ev 'Reestablishment')"
  RASTORM="$(ev 'no free RA process')"
  printf '  %-34s %s\n' "UL failures (PUSCH DTX)"      "$RLF"
  printf '  %-34s %s\n' "RRC re-establishments"        "$REEST"
  printf '  %-34s %s\n' "PRACH storm (no free RA)"     "$RASTORM"

  # Did the L1 actually detect preambles? Distinguishes "the UE never got on
  # the radio" from "it attached and the core refused it".
  kubectl exec -n "$NS" "$POD" -c nv-cubb -- \
    bash -c 'grep -iE "prach" /tmp/phy.log 2>/dev/null | tail -20' > "$L1LOG" 2>/dev/null

  step "N3 tunnel (UDP 2152)"
  UL=0; DL=0
  if [ -s "$PCAP" ]; then
    UL="$(sudo tcpdump -nr "$PCAP" "src host $N3" 2>/dev/null | wc -l)"
    DL="$(sudo tcpdump -nr "$PCAP" "dst host $N3" 2>/dev/null | wc -l)"
    sudo tcpdump -nr "$PCAP" 2>/dev/null | head -40 > "$OUT/n3-sample.txt"
    # Best effort: recent tcpdump decodes the inner packet of GTP-U, so the
    # sample often shows what the UE actually sent (ICMP, DNS, TCP).
    ECHOQ="$(grep -ci 'echo request' "$OUT/n3-sample.txt" 2>/dev/null)"; ECHOQ="${ECHOQ:-0}"
    ECHOR="$(grep -ci 'echo reply'   "$OUT/n3-sample.txt" 2>/dev/null)"; ECHOR="${ECHOR:-0}"
  fi
  printf '  %-34s %s\n' "uplink packets (gNB -> UPF)"   "$UL"
  printf '  %-34s %s\n' "downlink packets (UPF -> gNB)" "$DL"

  step "Verdict"
  # Check the radio BEFORE the tunnel: a UE that keeps re-establishing still
  # produces GTP-U packets, so tunnel counters alone read as healthy.
  if [ "${RLF:-0}" -gt 5 ] || [ "${REEST:-0}" -gt 2 ] || [ "${RASTORM:-0}" -gt 20 ]; then
    cat <<MSG
  THE RADIO LINK IS UNSTABLE -- fix this before looking at the core, whatever
  the tunnel counters below say. A UE that attaches, fails, and re-establishes
  still creates a PDU session and still moves some packets on N3.
    UL failures: $RLF   re-establishments: $REEST   phantom PRACH: $RASTORM
  "$RASTORM" phantom RA attempts means cuPHY is detecting preambles in noise;
  they also exhaust the RA process table and lock the real UE out. Check, in
  order: the RACH parameters (zeroCorrelationZoneConfig above all), the uplink
  power control (p0_nominal, preambleReceivedTargetPower), and only then the
  RF path. With the RU's own RSSI at thermal noise, the fault is in the DU's
  configuration, not in the air.
MSG
  elif [ "$RA" = 0 ] && [ "$RRC" = 0 ]; then
    cat <<MSG
  No UE reached the radio during this window. Either the UE never tried, or
  it cannot see the cell. Re-run while the UE is actively attaching.
MSG
  elif [ "$PDU" = 0 ]; then
    cat <<MSG
  The UE attached, but NO PDU SESSION was ever set up -- so there is no data
  path to break. That decision is made by the core, not by this DU:
    - is the subscriber provisioned for the DNN it is requesting? (UDM)
    - does the requested slice match what the gNB advertises (sst = 1)?
    - does the SMF have a UPF registered for that DNN?
  Ask the core team for the SMF/AMF logs at $(date +%H:%M) today.
MSG
    [ "$PDUFAIL" != 0 ] && echo "  NOTE: the gNB logged a PDU session failure/reject -- see $GNBLOG (the cause code names the reason)."
  elif [ "$UL" = 0 ] && [ "$DL" = 0 ]; then
    cat <<MSG
  A PDU session exists but NOT ONE packet crossed N3. The tunnel endpoints
  were created and nothing used them: check that the UE actually generated
  traffic during the window, then that the gNB's NGU address ($N3) is the one
  the core was told to use.
MSG
  elif [ "$DL" = 0 ]; then
    cat <<MSG
  Uplink leaves, NOTHING comes back. The UE's traffic reaches the UPF (or at
  least leaves this host) and the UPF never answers. This is beyond the DU:
    - is UDP 2152 permitted from $N3 to the UPF, and back? (SCTP being allowed
      does not mean GTP-U is -- that already bit this deployment once)
    - does the UPF have a route back to $N3?
    - is the UPF's N6 side able to reach the internet at all, and NATing the
      UE pool?
  Hand the core team: $PCAP
MSG
  else
    cat <<MSG
  The tunnel carries traffic BOTH WAYS -- the RAN and N3 are doing their job.
  What is left is past the UPF, so check in this order:
    1. DNS: from the UE, compare "ping 8.8.8.8" with "ping google.com".
       Reaching the IP but not the name = the SMF handed the UE a DNS server
       it cannot reach. Very common, and looks exactly like "no internet".
    2. MTU: from the UE, "ping -M do -s 1400 8.8.8.8". If that works while
       normal browsing hangs, the UE's MTU is too big for the GTP overhead --
       have the SMF advertise ~1400.
    3. N6/NAT on the UPF: does the UE's IP pool get NATed to the outside?
  Inner packets seen in the capture: echo requests=${ECHOQ:-?} replies=${ECHOR:-?}
  (requests with no replies points at 1 or 3; nothing at all means the UE was
  idle during the window.)
MSG
  fi

  echo
  echo "  files:"
  echo "    $GNBLOG          full gNB log for the window"
  echo "    $OUT/timeline.txt   just the attach/session events"
  echo "    $PCAP        N3 capture (open in Wireshark)"
  echo "    $OUT/n3-sample.txt  first packets, decoded"
  [ -s "$L1LOG" ] && echo "    $L1LOG       PRACH/RA activity seen by the L1"
}
trap finish INT TERM EXIT

step "Starting capture -- attach the UE now"
echo "   (Ctrl-C when the UE has tried, or wait ${DUR}s)"
# -U so packets hit the file immediately: a capture killed before its buffer
# flushes looks like an empty tunnel, which is exactly the wrong conclusion.
sudo tcpdump -ni any -U -s 200 -w "$PCAP" "udp port 2152" >/dev/null 2>&1 &
TD_PID=$!
sleep 1
kill -0 "$TD_PID" 2>/dev/null || die "tcpdump failed to start (needs sudo)"

kubectl logs -n "$NS" "$POD" -c oai-gnb -f --since=1s > "$GNBLOG" 2>/dev/null &
LOG_PID=$!

# Live view of the events that matter, so you can see progress as it happens.
PATTERN='msg3|ra-rnti|rrcsetup|rrcreconfiguration|initial ue|initial context|pdusession|pdu session|teid|gtpu|registration|fail|reject'
( tail -F "$GNBLOG" 2>/dev/null | grep --line-buffered -iE "$PATTERN" | tee "$OUT/timeline.txt" ) &
TAIL_PID=$!

SECS=0
while [ "$SECS" -lt "$DUR" ]; do
  sleep 5; SECS=$((SECS+5))
  kill -0 "$LOG_PID" 2>/dev/null || { echo "   (log stream ended -- pod restarted?)"; break; }
done
kill "$TAIL_PID" 2>/dev/null
finish
