#!/usr/bin/env bash
# Pull the three images the DU and CU run. READ-ONLY as far as the cluster is
# concerned: it only populates the local Docker image store.
#
#   ./scripts/5-images.sh
#
# Pins live in versions.env (override in config/versions.env):
#   IMAGE_DU_LOW   Aerial cuPHY — the L1 binary is inside the image
#   IMAGE_DU_HIGH  OAI MAC/RLC, built with nvIPC/Aerial support and the E2 agent.
#                  Runs on a DIFFERENT host from the L1 and is a different
#                  architecture, so it will not be in this node's image store.
#   IMAGE_CU       OAI RRC/PDCP/SDAP
#
# An image that is only in the local store — built on this box and never pushed
# — is reported as local rather than treated as an error: that is a normal state
# for the two OAI images, and 6-deploy.sh sets imagePullPolicy accordingly. It
# is also the thing that makes a deployment unreproducible on a second host, so
# the script says so out loud.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/config/versions.env" ] && . "$ROOT/config/versions.env"

step(){ printf '\n\033[1m>> %s\033[0m\n' "$*"; }
command -v docker >/dev/null 2>&1 || { echo "docker not installed" >&2; exit 1; }

rc=0; local_only=()
for var in IMAGE_DU_LOW IMAGE_DU_HIGH IMAGE_CU; do
  img="${!var:-}"
  [ -n "$img" ] || { echo "$var is unset in versions.env" >&2; rc=1; continue; }
  step "$var = $img"
  if docker pull "$img" 2>&1 | sed 's/^/   /'; then
    continue
  fi
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "   not in a registry, but present locally — will run from the local store"
    local_only+=("$var=$img")
  else
    echo "   NOT pullable and NOT present locally" >&2
    rc=1
  fi
done

if [ ${#local_only[@]} -gt 0 ]; then
  cat <<MSG

>> Local-only images: $(printf '%s ' "${local_only[@]}")
   These exist in this host's Docker store and in no registry, so this
   deployment cannot be reproduced on another machine as it stands. Push them
   to a registry and re-pin in config/versions.env when that matters.
MSG
fi
[ "$rc" = 0 ] || { echo; echo ">> Some images are missing. Fix the pins before deploying." >&2; exit 1; }
echo; echo ">> all three images available. Next: ./scripts/6-deploy.sh"
