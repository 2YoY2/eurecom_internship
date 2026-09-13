#!/usr/bin/env bash
# Build the RAN from the pristine sources in stack/. Nothing from a previous
# deployment is reused -- not its build tree, not its images, not its configs.
#
#   ./scripts/31-build-stack.sh          # build both
#   ./scripts/31-build-stack.sh l1       # Aerial cuBB only
#   ./scripts/31-build-stack.sh l2       # OAI gNB image only
#
# L1: cuBB is compiled INSIDE the Aerial container against the mounted source
#     tree, producing build.$(uname -m)/ -- the layout run_l1.sh expects.
# L2: OAI is built with nvIPC support so it speaks FAPI to Aerial. The nvIPC
#     sources ship inside the Aerial container and must be staged into the OAI
#     tree first; that is what makes `nfapi = "AERIAL"` compile.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/site/versions.env" ] && . "$ROOT/site/versions.env"
STACK="${STACK_DIR:-$ROOT/stack}"
AERIAL_SRC="$STACK/aerial-cuda-accelerated-ran"
OAI_SRC="$STACK/openairinterface5g"
ARCH="$(uname -m)"
WHAT="${1:-all}"

step() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Build containers get fixed names so an interrupted run can be cleaned up.
# Ctrl+C only detaches the docker CLI -- the container keeps running, and an
# anonymous one is then an orphan nobody recognises, still holding cores and
# the GPU. Reap any stale ones before starting.
BUILD_CT="aerial-cubb-build"
PACK_CT="aerial-nvipc-pack"
reap() {
  for n in "$BUILD_CT" "$PACK_CT"; do
    if docker ps -aq -f "name=^${n}$" | grep -q .; then
      echo ">> removing stale build container: $n"
      docker rm -f "$n" >/dev/null 2>&1
    fi
  done
}
reap
trap 'reap' EXIT INT TERM

[ -d "$AERIAL_SRC" ] || die "missing $AERIAL_SRC — run ./scripts/21-fetch-stack.sh"
docker image inspect "$AERIAL_IMAGE:$AERIAL_TAG" >/dev/null 2>&1 \
  || die "Aerial image $AERIAL_IMAGE:$AERIAL_TAG not present — run ./scripts/21-fetch-stack.sh"

# Provenance of the one artefact we do not build ourselves. A registry digest
# means the image came from NGC and matches what NGC published; a local build or
# a `docker commit` has no digest. If this prints none, re-pull before trusting
# it -- `docker pull` is a no-op when the local copy already matches.
DIGEST="$(docker image inspect -f '{{range .RepoDigests}}{{.}}{{end}}' "$AERIAL_IMAGE:$AERIAL_TAG" 2>/dev/null)"
if [ -n "$DIGEST" ]; then
  echo ">> Aerial image provenance: $DIGEST"
else
  echo ">> WARNING: Aerial image has NO registry digest — it was not pulled from"
  echo "   NGC, so its contents are unverified. Re-pull it:"
  echo "     docker login nvcr.io && docker pull $AERIAL_IMAGE:$AERIAL_TAG"
fi

# ------------------------------------------------------------------ L1
build_l1() {
  step "L1: compiling cuBB inside $AERIAL_TAG (target: build.$ARCH)"
  if [ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ]; then
    echo "   already built — delete build.$ARCH to force a rebuild"
    return 0
  fi
  # Use the release's OWN build entry point. Inventing a cmake line risks
  # building with different flags than the release expects, which surfaces much
  # later as subtle runtime failure rather than an honest compile error.
  # run_l1.sh names the first of these in its header comment.
  local cmd="" script=""
  for c in testBenches/phase4_test_scripts/build_aerial_sdk.sh \
           cubb_scripts/build.sh cubb_scripts/install/build.sh build.sh; do
    [ -f "$AERIAL_SRC/$c" ] && { script="$c"; break; }
  done
  if [ -n "$script" ]; then
    echo "   using in-tree build script: $script"
    # The preset is NOT optional. OAI frames every FAPI TLV with a 16-bit
    # length field; Aerial's default (perf) preset compiles the L1 with
    # SCF_FAPI_10_04=ON, whose TLV header carries a 32-bit length. A default-
    # built L1 misreads the first TLV's length as megabytes, walks off the end
    # of the CONFIG.request, logs every remaining TLV as "Unknown TLV 0", and
    # rejects the cell with "pOccaPrms is null". The 10_02 preset plus the
    # 10.04 SRS PDU flag is the exact pairing OAI's Aerial tutorial mandates.
    # AERIAL_CUDA_ARCHS=121 skips the other CUDA targets (GB10 is sm_121).
    case "$script" in
      *build_aerial_sdk.sh)
        cmd="bash '$script' --preset 10_02 ${AERIAL_CUDA_ARCHS:+--cuda-archs $AERIAL_CUDA_ARCHS} -- -DSCF_FAPI_10_04_SRS=ON -DENABLE_CONFORMANCE_TM_PDSCH_PDCCH=OFF" ;;
      *)
        cmd="bash '$script'" ;;
    esac
  else
    echo "   No in-tree build script found. What this release ships:"
    ls -1 "$AERIAL_SRC"/*.sh 2>/dev/null | sed 's|.*/|     |'
    ls -1 "$AERIAL_SRC"/cubb_scripts/ 2>/dev/null | sed 's/^/     cubb_scripts\//'
    ls -1 "$AERIAL_SRC"/testBenches/phase4_test_scripts/ 2>/dev/null | head -10 | sed 's/^/     testBenches\/phase4_test_scripts\//'
    [ -f "$AERIAL_SRC/CMakeLists.txt" ] && echo "     (CMakeLists.txt is present)"
    die "cannot pick a build command safely — tell me which of the above to use"
  fi
  # isolcpus removes cores 4-19 from the default affinity mask, so an
  # unconstrained build container sees only the housekeeping cores -- on a
  # 20-core box that is a 4-core build. The RAN is not running during a build,
  # so hand it the whole machine. Override with BUILD_CPUS if the RAN is live.
  # (Expect PTP rms to wobble while this runs; it re-locks afterwards.)
  local ncpu; ncpu="$(nproc --all 2>/dev/null || nproc)"
  local cpus="${BUILD_CPUS:-0-$((ncpu - 1))}"
  echo "   building on cores $cpus (host has $ncpu; without this it would use $(nproc))"

  # SYS_NICE silences the chrt warning: the build script tries to set a
  # real-time policy for itself. Harmless when denied, but noisy.
  # --user 0:0: the NGC image's default user is "aerial", which cannot write
  # into a bind-mounted tree owned by whoever cloned it. The build has always
  # been root-owned on the host (see the chown below); make that explicit
  # instead of depending on the image's USER line. Invoke the scripts through
  # bash rather than chmod+exec for the same reason: a checkout without the
  # execute bit must not be a build failure.
  docker run --rm --name "$BUILD_CT" --gpus all \
    --cpuset-cpus="$cpus" \
    --cap-add=SYS_NICE --user 0:0 \
    -v "$AERIAL_SRC":/opt/nvidia/cuBB \
    -v /usr/src:/usr/src -v /lib/modules:/lib/modules \
    -w /opt/nvidia/cuBB \
    -e cuBB_SDK=/opt/nvidia/cuBB \
    "$AERIAL_IMAGE:$AERIAL_TAG" \
    bash -lc "$cmd" || die "cuBB build failed (see output above)"

  # The container builds as root, so the output would be root-owned on the host
  # and need sudo to clean up or rebuild later.
  if [ -d "$AERIAL_SRC/build.$ARCH" ] && [ "$(stat -c %u "$AERIAL_SRC/build.$ARCH")" = 0 ] && [ "$(id -u)" != 0 ]; then
    echo "   returning ownership of build.$ARCH to $(id -un)"
    sudo chown -R "$(id -u):$(id -g)" "$AERIAL_SRC/build.$ARCH" 2>/dev/null || \
      echo "   (could not chown; you will need sudo to remove build.$ARCH)"
  fi

  [ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ] \
    || die "build finished but cuphycontroller_scf is missing from build.$ARCH"
  echo "   built: build.$ARCH/.../cuphycontroller_scf"
}

# ------------------------------------------------------------------ L2
build_l2() {
  [ -d "$OAI_SRC" ] || die "missing $OAI_SRC — run ./scripts/21-fetch-stack.sh"

  step "L2: generating nvIPC sources (pack_nvipc.sh)"
  # The tarball is NOT shipped -- not in git, not in the image. It is GENERATED
  # from the cuBB tree by pack_nvipc.sh, per OAI's Aerial FAPI split tutorial.
  # That is why a long-lived host accumulates several of them bearing different
  # dates: one per time somebody packed.
  #
  # Packing from the tree we just built is also what guarantees compatibility:
  # the nvIPC the L2 links against comes from the same source as the L1 it will
  # talk to, so the FAPI contract cannot drift between them.
  local GTL="$AERIAL_SRC/cuPHY-CP/gt_common_libs"
  [ -f "$GTL/pack_nvipc.sh" ] || die "pack_nvipc.sh not found in $GTL"

  docker run --rm --name "$PACK_CT" --user 0:0 \
    -v "$AERIAL_SRC":/opt/nvidia/cuBB \
    -w /opt/nvidia/cuBB/cuPHY-CP/gt_common_libs \
    -e cuBB_SDK=/opt/nvidia/cuBB \
    "$AERIAL_IMAGE:$AERIAL_TAG" \
    bash -lc "bash pack_nvipc.sh" \
    || die "pack_nvipc.sh failed"

  # It runs as root against a bind mount; hand the result back to the user.
  [ "$(id -u)" != 0 ] && sudo chown "$(id -u):$(id -g)" "$GTL"/nvipc_src.*.tar.gz 2>/dev/null
  local tb; tb="$(ls -1t "$GTL"/nvipc_src.*.tar.gz 2>/dev/null | head -1)"
  [ -n "$tb" ] || die "pack_nvipc.sh ran but produced no tarball in $GTL"

  # The Dockerfile does `tar -xvzf nvipc_src.*.tar.gz`, so exactly one may be
  # present in the build context -- a second one makes that glob fail.
  rm -f "$OAI_SRC"/nvipc_src.*.tar.gz
  cp -f "$tb" "$OAI_SRC/"
  echo "   packed and staged: $(basename "$tb")"

  step "L2: building the OAI gNB image with the Aerial FAPI split"
  # Match on BASENAMES, never on full paths: this repo lives under a directory
  # called aerial-k3s, so filtering `ls` output by "aerial" silently discards
  # every candidate. Work inside docker/ so only filenames are ever compared.
  local dfn
  dfn="$(cd "$OAI_SRC/docker" 2>/dev/null && ls -1 Dockerfile.*aerial* 2>/dev/null \
         | grep -v sanitize | head -1)"          # sanitizer variants are for debugging
  if [ -z "$dfn" ]; then
    echo "   No Aerial Dockerfile found. Available:"
    ls -1 "$OAI_SRC"/docker/ 2>/dev/null | sed 's/^/     /'
    die "cannot build L2 without an Aerial gNB Dockerfile"
  fi
  local df="$OAI_SRC/docker/$dfn"
  echo "   dockerfile: $dfn"

  # OAI builds in stages: base -> build -> target.
  #
  # These are rebuilt every time on purpose. An existing ran-base/ran-build on
  # a reused host was produced by whoever set the box up before, from sources
  # and flags nobody can now inspect -- and it would silently become a layer
  # underneath the image we ship. "Fresh" has to mean the whole chain, not just
  # the top of it. Set REUSE_BASE=1 to trade that guarantee for build time.
  # Only ran-base. The gNB Dockerfile is multi-stage and defines its own
  # `ran-build` stage FROM ran-base, so building a separate ran-build image
  # would be dead work that nothing consumes.
  # The gNB Dockerfile starts FROM ran-base:latest, so that image must exist
  # first. Its Dockerfile has been named several ways across OAI releases, so
  # match loosely rather than pinning one spelling.
  # The base MUST match the gNB Dockerfile's OS family. OAI ships base images
  # for ubuntu, rocky and rhel9; an alphabetical pick lands on rhel9 and would
  # put a RHEL userland underneath an Ubuntu gNB image. Derive it instead:
  #   Dockerfile.gNB.aerial.ubuntu  ->  Dockerfile.base.ubuntu
  local osfam="${dfn##*.}"
  local sdf="$OAI_SRC/docker/Dockerfile.base.$osfam"
  if [ ! -f "$sdf" ]; then
    echo "   No Dockerfile.base.$osfam to match $dfn. This release ships:"
    ls -1 "$OAI_SRC"/docker/ | grep -i base | sed 's/^/     /'
    die "cannot build a ran-base matching the gNB image's OS family"
  fi
  if [ "${REUSE_BASE:-0}" = 1 ] && docker image inspect ran-base:latest >/dev/null 2>&1; then
    echo "   ran-base:latest present and REUSE_BASE=1 — reusing an inherited image"
  else
    echo "   building ran-base:latest from $(basename "$sdf")"
    docker build --pull -t ran-base:latest -f "$sdf" "$OAI_SRC" || die "ran-base build failed"
  fi

  docker build -t oai-gnb-aerial:latest -f "$df" "$OAI_SRC" \
    || die "oai-gnb-aerial build failed"
  # Record what the image was built from. 34-deploy-du.sh refuses to deploy an
  # image whose provenance it cannot match to the current checkout: a stale
  # oai-gnb-aerial:latest from an earlier setup speaks a different FAPI
  # encoding and fails at CONFIG.request, far from any hint of the cause.
  git -C "$OAI_SRC" rev-parse HEAD > "$STACK/.oai-gnb-aerial.commit" 2>/dev/null \
    && echo "   provenance: $(cat "$STACK/.oai-gnb-aerial.commit")"
  echo "   built: oai-gnb-aerial:latest"
}

case "$WHAT" in
  l1)  build_l1 ;;
  l2)  build_l2 ;;
  all) build_l1; build_l2 ;;
  *)   die "usage: $0 [l1|l2|all]" ;;
esac

step "Result"
docker images --format '   {{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null \
  | grep -E 'oai-gnb-aerial|ran-base|ran-build' || echo "   (no OAI images)"
[ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ] \
  && echo "   L1 binary: $AERIAL_SRC/build.$ARCH/..." \
  || echo "   L1 binary: NOT BUILT"
