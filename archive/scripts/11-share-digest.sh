#!/usr/bin/env bash
# Print a paste-sized, secret-redacted digest of an inventory capture.
#
#   ./scripts/11-share-digest.sh                  # newest capture under $HOME
#   ./scripts/11-share-digest.sh <inventory-dir>  # a specific one
#
# Why this exists: docker inspect records every container's full environment,
# which on an Aerial host routinely includes NGC_API_KEY or registry logins.
# The raw capture is safe on the box but NOT safe to paste around.
#
# Still present after redaction: MACs, IPs, PCIe addresses, RU parameters —
# they are exactly what you need to rebuild the fronthaul, so they stay.
# Fine to paste into a working chat. Do NOT commit it: this repo is public
# (.gitignore already blocks aerial-inventory-*).
set -uo pipefail

DIR="${1:-$(ls -dt "$HOME"/aerial-inventory-*/ 2>/dev/null | head -1)}"
[ -n "${DIR:-}" ] && [ -d "$DIR" ] || {
  echo "No inventory found. Run scripts/10-inventory-server.sh first." >&2; exit 1; }
DIR="${DIR%/}"

# Blank out secret-shaped values wherever they appear.
. "$(dirname "$0")/lib-redact.sh"

sec() { printf '\n===== %s =====\n' "$*"; }

# show <label> <relative-file> [maxlines]
show() {
  local f="$DIR/$2" n="${3:-60}" t
  sec "$1"
  if [ -s "$f" ]; then
    head -n "$n" "$f" | redact
    t=$(wc -l < "$f")
    [ "$t" -gt "$n" ] && echo "... [$((t - n)) more lines in $2]"
  else
    echo "(empty or not collected)"
  fi
}

echo "########## INVENTORY DIGEST: $(basename "$DIR") ##########"
show "SUMMARY"              SUMMARY.txt              40
show "KERNEL CMDLINE + CPU" host/host.txt            45
show "HUGEPAGES"            host/hugepages.txt       15
show "PROCESSES OF INTEREST" host/processes-of-interest.txt 20

sec "GPU"
head -n 20 "$DIR/gpu/gpu.txt" 2>/dev/null | redact
show "NVIDIA/CUDA PACKAGES"  gpu/packages.txt         40

show "CONTAINERS (all, incl. stopped)" docker/ps.txt 30
show "IMAGES"               docker/images.txt        40
show "CONTAINER RECIPES"    docker/summary.txt       160
show "COMPOSE FILES FOUND"  docker/compose-files-found.txt 20
show "COMPOSE CONTENT"      docker/compose-files-content.txt 120

show "NIC / SR-IOV"         net/interfaces.txt       80
show "PTP"                  ptp/ptp.txt              50

show "AERIAL CONFIG FILES FOUND" aerial/config-files-found.txt 20
# The Aerial YAMLs are the crown jewels — cell config, eAxC, fronthaul MACs.
sec "AERIAL CONFIG CONTENT"
if [ -d "$DIR/aerial/files" ]; then
  find "$DIR/aerial/files" -type f | head -8 | while read -r f; do
    printf -- '--- %s ---\n' "${f#"$DIR/aerial/files"}"
    head -n 120 "$f" | redact
    echo
  done
else
  echo "(no config files were copied)"
fi

show "GIT CHECKOUTS (which release was built)" aerial/git-repos.txt 60
show "FRONTHAUL PARAMS"     ru/fronthaul-params.txt  60
show "RU / ARP"             ru/ru.txt                30
show "K8S TOOLS PRESENT"    k8s/tools.txt            15

printf '\n########## END DIGEST ##########\n'
