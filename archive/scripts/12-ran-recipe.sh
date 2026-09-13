#!/usr/bin/env bash
# Print the exact launch recipe for the Aerial L1 + OAI L2 stack, redacted.
#
#   ./scripts/12-ran-recipe.sh
#
# The inventory (script 10) tells you what the box HAS. This tells you how the
# RAN was actually STARTED: the L1 run script, the L2 compose file, the nvIPC
# adapter config, the fronthaul cell block, and — most valuable — the local
# diffs against upstream, which are the site-specific customisations you must
# carry into Kubernetes.
#
# Read-only. Paste the output into the working chat; secrets are redacted.
set -uo pipefail

. "$(dirname "$0")/lib-redact.sh"

# Locate the trees by their git remote, so this works on any box.
#
# Once 21-fetch-stack.sh has run there are at least two clones of each repo: the
# pristine one under stack/ and the deployment's own working tree. The pristine
# clone has no local changes, so picking it yields an empty diff and tells you
# nothing. Prefer a tree with uncommitted modifications -- that is the one
# somebody actually configured -- and never pick our own stack/ clone.
SELF_STACK="$(cd "$(dirname "$0")/.." && pwd)/stack"
# find_repo is called from a command substitution, i.e. a subshell, so it cannot
# report the candidate list back through a variable. Collect it in a file.
CAND_FILE="$(mktemp)"
trap 'rm -f "$CAND_FILE"' EXIT
# Emit EVERY modified tree, not just one. A box that has been worked on for a
# while accumulates several generations of the same repo (e.g. an old 25-3
# experiment beside the live 26-1 tree), and picking one means picking wrong
# roughly half the time -- silently. Dump them all and let the reader judge.
# Falls back to clean trees only if nothing is modified.
find_repos() {  # find_repos <remote-substring>
  local m="$1" g r dirty="" clean=""
  while read -r g; do
    r="$(dirname "$g")"
    case "$r" in "$SELF_STACK"/*|"$SELF_STACK") continue ;; esac
    git -C "$r" remote -v 2>/dev/null | grep -qi "$m" || continue
    if [ -n "$(git -C "$r" status -s 2>/dev/null)" ]; then
      echo "    modified: $r ($(git -C "$r" describe --tags --always 2>/dev/null))" >> "$CAND_FILE"
      dirty="$dirty$r"$'\n'
    else
      echo "    clean   : $r ($(git -C "$r" describe --tags --always 2>/dev/null))" >> "$CAND_FILE"
      clean="$clean$r"$'\n'
    fi
  done < <(find "$HOME" -maxdepth 6 -name .git -type d 2>/dev/null)
  [ -n "$dirty" ] && { printf '%s' "$dirty"; return 0; }
  printf '%s' "$clean"
}

AERIAL_TREES="${AERIAL_REPO:-$(find_repos 'aerial-cuda-accelerated-ran')}"
OAI_TREES="${OAI_REPO:-$(find_repos 'openairinterface5g')}"
# versions.env names the release we intend to run; flag the tree that matches.
PINNED_REF="$(. "$(dirname "$0")/../versions.env" 2>/dev/null; echo "${AERIAL_SRC_REF:-}")"

sec() { printf '\n===== %s =====\n' "$*"; }
# cat_file <label> <path> [maxlines]
cat_file() {
  local n="${3:-120}" t
  sec "$1"
  if [ -f "$2" ]; then
    echo "# path: $2"
    head -n "$n" "$2" | redact
    t=$(wc -l < "$2"); [ "$t" -gt "$n" ] && echo "... [$((t - n)) more lines]"
  else
    echo "(not found: $2)"
  fi
}

echo "########## RAN LAUNCH RECIPE ##########"
echo "pinned Aerial ref (versions.env): ${PINNED_REF:-unset}"
if [ -s "$CAND_FILE" ]; then
  echo "trees found (stack/ skipped; ALL modified ones are dumped below):"
  sort -u "$CAND_FILE"
fi

sec "BOOT PARAMETERS (isolcpus / hugepages / iommu)"
cat /proc/cmdline

sec "CUDA MPS STATE"
# -f is required: pgrep matches only the first 15 chars of a process NAME,
# so "nvidia-cuda-mps-control" never matches without full-cmdline matching.
pgrep -af nvidia-cuda-mps-control || echo "mps-control: not running"
pgrep -af nvidia-cuda-mps-server  || echo "mps-server:  not running"
ls -ld /tmp/nvidia-mps 2>/dev/null || echo "/tmp/nvidia-mps: absent"
echo "CUDA_MPS_* in this shell:"; env | grep -E '^CUDA_MPS' || echo "(none)"

sec "IRQ / TUNING SERVICES"
systemctl list-unit-files --state=enabled --no-pager 2>/dev/null \
  | grep -iE 'ptp|phc|irq|tuned|cpu|nvidia|mps|aerial' || echo "(none matched)"

# ---------------------------------------------------------------- Aerial L1
printf '%s\n' "$AERIAL_TREES" | while read -r AERIAL; do
  [ -n "$AERIAL" ] || continue
  VER="$(git -C "$AERIAL" describe --tags --always 2>/dev/null)"
  MARK=""; [ -n "$PINNED_REF" ] && [ "$VER" = "$PINNED_REF" ] && MARK="  <<< MATCHES PINNED REF"
  sec "AERIAL TREE: $AERIAL ($VER)$MARK"
  git -C "$AERIAL" log -1 --oneline 2>&1
  git -C "$AERIAL" status -s 2>&1 | head -30

  sec "AERIAL DIFF vs UPSTREAM — $VER (the site-specific customisation)"
  git -C "$AERIAL" diff 2>/dev/null | redact | head -200
  echo "... [diff capped at 200 lines per tree]"

  cat_file "AERIAL run_l1.sh — $VER"  "$AERIAL/run_l1.sh"                 90
  cat_file "AERIAL versions.sh"       "$AERIAL/cubb_scripts/install/versions.sh" 40
  # NVIDIA ships a config per reference platform/RU, so never hardcode one
  # filename. The file actually in use is the one git reports as modified;
  # everything else is stock and tells you nothing about this deployment.
  CFG="$AERIAL/cuPHY-CP/cuphycontroller/config"
  sec "AERIAL: CONFIGS PRESENT (modified = the live one)"
  ls -1 "$CFG"/*.yaml 2>/dev/null | sed "s|.*/||" | head -20
  echo "-- locally modified:"
  git -C "$AERIAL" status -s -- "$CFG" 2>/dev/null | head -10 || echo "(none)"

  # Prefer the modified configs; fall back to whatever exists, capped.
  mapfile -t LIVE < <(git -C "$AERIAL" status -s --porcelain -- "$CFG" 2>/dev/null \
                        | awk '{print $NF}' | grep -E '\.yaml$' | head -4)
  if [ "${#LIVE[@]}" -eq 0 ]; then
    mapfile -t LIVE < <(cd "$AERIAL" 2>/dev/null && ls -1 "$CFG"/*.yaml 2>/dev/null | head -2)
  fi
  for f in "${LIVE[@]}"; do
    [ -n "$f" ] || continue
    p="$f"; [ -f "$p" ] || p="$AERIAL/$f"
    [ -f "$p" ] || continue
    case "$(basename "$p")" in
      l2_adapter*) cat_file "AERIAL nvIPC: $(basename "$p")" "$p" 100 ;;
      *)           sec "AERIAL FRONTHAUL: $(basename "$p")"
                   sed -n '/cell_configs:/,$p' "$p" | head -60 | redact
                   grep -nE 'aerial_sdk_version|l2adapter_filename|nic:|workers_|low_priority_core' "$p" | head -15 ;;
    esac
  done
done

# The live compose bind-mounts a cuBB tree into the L1 container; that path is
# the ground truth for which tree is actually running, and it is often NOT one
# of the git checkouts found above.
sec "cuBB TREE REFERENCED BY THE LIVE COMPOSE"
for p in "$HOME/aerial-cuda-accelerated-ran" /opt/nvidia/cuBB /opt/cuBB; do
  if [ -e "$p" ]; then
    printf '%s -> %s\n' "$p" "$(readlink -f "$p")"
    [ -d "$p/.git" ] && echo "   git: $(git -C "$p" describe --tags --always 2>/dev/null) $(git -C "$p" status -s 2>/dev/null | head -5 | tr '\n' ' ')"
    ls -1 "$p" 2>/dev/null | head -8 | sed 's/^/   /'
  else
    echo "$p: absent"
  fi
done

# ---------------------------------------------------------------- OAI L2/L3
printf '%s\n' "$OAI_TREES" | while read -r OAI; do
  [ -n "$OAI" ] || continue
  D="$OAI/ci-scripts/yaml_files/sa_gnb_aerial"
  sec "OAI TREE: $OAI"
  git -C "$OAI" describe --tags --always 2>&1
  git -C "$OAI" status -s 2>&1 | head -30

  cat_file "OAI: docker-compose.yaml (CURRENT)"   "$D/docker-compose.yaml"            120
  cat_file "OAI: .env"                            "$D/.env"                            40
  # What the k3s attempt looked like before and after it broke
  cat_file "OAI: docker-compose.yaml.pre-k3s"     "$D/docker-compose.yaml.pre-k3s"    120
  cat_file "OAI: docker-compose.yaml.broken-aug21" "$D/docker-compose.yaml.broken-aug21" 120
  cat_file "OAI: docker-compose-ue.yaml"          "$D/docker-compose-ue.yaml"          60

  sec "OAI: DIFF vs UPSTREAM"
  git -C "$OAI" diff 2>/dev/null | redact | head -250
  echo "... [diff capped at 250 lines per tree]"
done

sec "RAN-RELATED IMAGES"
docker images 2>/dev/null | grep -iE 'aerial|oai|ran-|rancher|nvcr' || echo "(none)"

printf '\n########## END RECIPE ##########\n'
