#!/usr/bin/env bash
# Build and start a dApp — a real-time application co-located with the gNB that
# reads PHY/MAC telemetry over the E3 interface at sub-10 ms timescales.
#
#   ./scripts/22-build-dapp.sh                 # embedded-Python variant (default)
#   VARIANT=triton ./scripts/22-build-dapp.sh  # Triton C API (lowest latency)
#   VARIANT=triton-grpc ./scripts/22-build-dapp.sh
#
# Variants, per NVIDIA's framework:
#   python       embedded Python — easiest to develop against
#   triton       Triton C API, in-process — lowest latency (~150 us overhead)
#   triton-grpc  Triton as a separate process — adds ~200 us serialisation
#
# PREREQUISITE, and the usual reason this silently does nothing: the L1 must be
# started with the E3 agent switched on. In the cuphycontroller YAML you need
# `data_core` set and `e3_agent_enable` true. Without that there is no agent for
# the dApp's E3 Manager to subscribe to, and the dApp just waits forever.
#
# On GB10 there is no MIG, so the dApp shares the GPU with the L1 through CUDA
# MPS. The L1 keeps priority: its SM budget is fixed by the mps_sm_* keys in the
# same YAML.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/site/versions.env" ] && . "$ROOT/site/versions.env"

STACK="${STACK_DIR:-$ROOT/stack}"
APPS="$STACK/aerial-sample-apps"
VARIANT="${VARIANT:-python}"
CUBB_CONTAINER="${CUBB_CONTAINER:-nv-cubb}"
APPDIR="$APPS/applications/prb-power-${VARIANT}"

[ -d "$APPS" ] || { echo "Sample apps not fetched. Run: ./scripts/21-fetch-stack.sh" >&2; exit 1; }
if [ ! -d "$APPDIR" ]; then
  echo "No such variant: prb-power-$VARIANT" >&2
  echo "Available:" >&2
  ls -1 "$APPS/applications" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

echo ">> variant        : prb-power-$VARIANT"
echo ">> cuBB container : $CUBB_CONTAINER"

# The dApp reaches the L1's E3 agent through the cuBB container's IPC namespace,
# so e3_config.json must name the container actually running L1.
CFG="$APPDIR/config/e3_config.json"
[ -f "$CFG" ] || CFG="$(find "$APPDIR" -name e3_config.json | head -1)"
if [ -f "$CFG" ]; then
  echo ">> e3 config      : $CFG"
  if grep -q "$CUBB_CONTAINER" "$CFG" 2>/dev/null; then
    echo "   ipc_mode already references $CUBB_CONTAINER"
  else
    echo "   NOTE: ipc_mode does not mention '$CUBB_CONTAINER'. Current value:"
    grep -n 'ipc_mode' "$CFG" | sed 's/^/     /'
    echo "   Edit it to match your L1 container name, or set CUBB_CONTAINER."
  fi
else
  echo ">> e3 config      : not found (check $APPDIR/config/)"
fi

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CUBB_CONTAINER"; then
  echo ">> WARNING: container '$CUBB_CONTAINER' is not running."
  echo "   The dApp will build, but it cannot subscribe until L1 is up with the"
  echo "   E3 agent enabled (data_core + e3_agent_enable in the cuphycontroller YAML)."
fi

echo
echo ">> building and starting (restart_script.sh) — first build is slow (~20 GB image)"
cd "$APPDIR" || exit 1
if [ ! -x ./restart_script.sh ]; then
  echo "restart_script.sh missing or not executable in $APPDIR" >&2
  ls -1 >&2; exit 1
fi
./restart_script.sh
rc=$?

echo
if [ $rc -eq 0 ]; then
  echo ">> dApp container: dapp-prb-power-$VARIANT"
  docker ps --filter "name=dapp-prb-power" --format '   {{.Names}}\t{{.Status}}'
  echo ">> logs: docker logs -f dapp-prb-power-$VARIANT"
else
  echo ">> restart_script.sh exited $rc — see output above."
fi
exit $rc
