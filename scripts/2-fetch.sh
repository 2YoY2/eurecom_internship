#!/usr/bin/env bash
# Fetch the whole RAN stack from scratch: Aerial L1 image + source, the matching
# OAI L2/L3 branch, and the dApp framework. Nothing here is site-specific.
#
#   ./scripts/2-fetch.sh
#
# Everything lands in ./stack/ (untracked). Re-running is safe: existing clones
# are fetched and checked out to the pinned ref, existing images are skipped.
#
# The Aerial image pulls anonymously from NGC -- no login, no API key. If a
# future release turns out to be gated, the pull fails with a clear auth error
# and you run `docker login nvcr.io` yourself; this script never handles keys.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/config/versions.env" ] && . "$ROOT/config/versions.env"

STACK="${STACK_DIR:-$ROOT/stack}"
mkdir -p "$STACK"
fail=0
step() { printf '\n>> %s\n' "$*"; }

# clone_at <url> <ref> <dest>
clone_at() {
  local url="$1" ref="$2" dest="$3" name; name="$(basename "$dest")"
  if [ -d "$dest/.git" ]; then
    step "$name: updating to $ref"
    git -C "$dest" fetch --depth 1 origin "$ref" 2>&1 | tail -2
    git -C "$dest" checkout -q FETCH_HEAD 2>/dev/null || git -C "$dest" checkout -q "$ref" || {
      echo "   could not check out $ref"; fail=1; return 1; }
  else
    step "$name: cloning $ref"
    git clone --depth 1 --branch "$ref" "$url" "$dest" 2>&1 | tail -2 || {
      echo "   clone failed: $url ($ref)"; fail=1; return 1; }
  fi
  echo "   at $(git -C "$dest" rev-parse --short HEAD)"
}

# ---------------------------------------------------------------- Aerial L1
step "Aerial L1 image: $AERIAL_IMAGE:$AERIAL_TAG"
# Check for the image BEFORE checking credentials: a box that already has it
# needs no NGC login at all, and demanding one there is just a false alarm.
# Always pull. When the local copy already matches the registry this is a no-op
# that prints "Image is up to date", and it simultaneously PROVES the local copy
# is byte-identical to what NGC published -- which matters on a reused host,
# where an inherited image is otherwise just something that happens to be there.
echo "   pulling (no-op if already current; ~26 GB on a cold host)..."
if docker pull "$AERIAL_IMAGE:$AERIAL_TAG"; then
  echo "   digest: $(docker image inspect -f '{{range .RepoDigests}}{{.}}{{end}}' "$AERIAL_IMAGE:$AERIAL_TAG" 2>/dev/null)"
else
  echo "   pull failed. If this is an auth error, run: docker login nvcr.io"
  fail=1
fi

# Source tree: config templates, run_l1.sh, and the cuBB build scripts. The
# public release ships no DGX Spark cuphycontroller/l2-adapter YAML, so the
# per-site config is derived from these templates -- you need the tree.
clone_at "$AERIAL_SRC_URL" "$AERIAL_SRC_REF" "$STACK/aerial-cuda-accelerated-ran"

# ---------------------------------------------------------------- OAI L2/L3
# Must be the branch matching the Aerial release: the nFAPI/nvIPC contract
# changes between releases and mismatches fail at handshake, not at build.
clone_at "$OAI_URL" "$OAI_REF" "$STACK/openairinterface5g"

# ---------------------------------------------------------------- dApp
clone_at "$SAMPLE_APPS_URL" "$SAMPLE_APPS_REF" "$STACK/aerial-sample-apps"

step "Summary"
printf '   stack dir : %s\n' "$STACK"
for d in aerial-cuda-accelerated-ran openairinterface5g aerial-sample-apps; do
  if [ -d "$STACK/$d/.git" ]; then
    printf '   %-32s %s\n' "$d" "$(git -C "$STACK/$d" rev-parse --short HEAD)"
  else
    printf '   %-32s MISSING\n' "$d"
  fi
done
docker image inspect "$AERIAL_IMAGE:$AERIAL_TAG" >/dev/null 2>&1 \
  && printf '   %-32s %s\n' "aerial image" "$AERIAL_TAG" \
  || printf '   %-32s MISSING\n' "aerial image"

if [ "$fail" -ne 0 ]; then
  echo
  echo ">> incomplete — see the messages above."
  exit 1
fi
cat <<EOF

>> stack fetched. These trees are read for their config TEMPLATES; nothing here
   is compiled. Next:
   1. cp config/site.example.yaml config/site.yaml  and fill it in
   2. ./scripts/3-cluster.sh
EOF
