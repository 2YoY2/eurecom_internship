#!/usr/bin/env bash
# What is still missing between "the host is ready" and "the CU and DU can
# start"? READ-ONLY: it changes nothing, on the host or in the cluster.
#
#   ./scripts/check.sh
#
# Everything it knows about your deployment it reads from config/, so nothing
# about it is hardcoded in this repo.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/config/versions.env" ] && . "$ROOT/config/versions.env"
RENDERED="$ROOT/config/rendered"

ok()   { printf '  \033[32mOK  \033[0m  %s\n' "$*"; }
gap()  { printf '  \033[31mGAP \033[0m  %s\n' "$*"; }
info() { printf '  ....  %s\n' "$*"; }
sec()  { printf '\n== %s ==\n' "$*"; }

sec "1. Site values"
if [ -f "$ROOT/config/site.yaml" ]; then
  ok "config/site.yaml exists"
else
  gap "no config/site.yaml — cp config/site.example.yaml config/site.yaml and fill it in"
fi

sec "2. Rendered configs"
# The L1 binary is inside the image now, so there is no build tree to look for.
# What has to exist on disk is the configuration derived from site.yaml.
for f in cuphycontroller_site.yaml l2_adapter_config_site.yaml gnb-du.conf gnb-cu.conf; do
  [ -f "$RENDERED/$f" ] && ok "$f" || gap "$f missing — run ./scripts/4-render.sh"
done
for f in l1-config.yaml oai-du-conf.yaml oai-cu-conf.yaml; do
  [ -f "$RENDERED/manifests/$f" ] && ok "manifest $f" \
    || gap "manifest $f missing — run ./scripts/4-render.sh"
done

sec "3. Images"
# Pulled, not built. An image present only locally still runs here; it just
# cannot be reproduced anywhere else.
if command -v docker >/dev/null 2>&1; then
  for var in IMAGE_L1 IMAGE_DU IMAGE_CU; do
    img="${!var:-}"
    [ -n "$img" ] || { gap "$var unset in versions.env"; continue; }
    docker image inspect "$img" >/dev/null 2>&1 \
      && ok "$var $img" \
      || gap "$var $img not in the local store — run ./scripts/5-images.sh"
  done
else
  gap "docker not installed"
fi

sec "4. 5G core reachability"
# The AMF belongs to the CU: a DU never speaks NGAP, so this reads gnb-cu.conf.
CONF="$RENDERED/gnb-cu.conf"
if [ -f "$CONF" ]; then
  AMF="$(grep -oE 'ipv4[[:space:]]*=[[:space:]]*"[0-9.]+"' "$CONF" | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)"
  LOCAL="$(grep -oE 'GNB_IPV4_ADDRESS_FOR_NG_AMF[^"]*"[0-9./]+"' "$CONF" | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)"
  info "AMF: ${AMF:-none}   CU N2 address: ${LOCAL:-none}"
  if [ -n "$LOCAL" ]; then
    ip -4 addr show 2>/dev/null | grep -q "$LOCAL" && ok "$LOCAL is configured on this host" \
      || gap "$LOCAL is NOT on any interface here — the CU cannot bind N2/N3"
  fi
  if [ -n "$AMF" ]; then
    ping -c1 -W2 "$AMF" >/dev/null 2>&1 && ok "AMF $AMF responds to ping" \
      || gap "AMF $AMF unreachable — the CU will retry NG Setup forever"
    # nc cannot probe SCTP: a TCP probe of 38412 fails against a healthy AMF.
    if command -v ncat >/dev/null 2>&1; then
      ncat --sctp -z -w2 "$AMF" 38412 >/dev/null 2>&1 && ok "SCTP 38412 open on the AMF" \
        || info "SCTP 38412 did not answer (it may still be filtered rather than down)"
    else
      info "install ncat to test SCTP 38412 — do not use nc, it cannot speak SCTP"
    fi
  fi
else
  gap "no rendered CU config — run ./scripts/4-render.sh"
fi

sec "5. Fronthaul / RU"
RU_MAC="$(grep -ohiE 'dst_mac_addr:[[:space:]]*([0-9a-f]{2}:){5}[0-9a-f]{2}' \
          "$RENDERED"/cuphycontroller_*.yaml 2>/dev/null | head -1 | awk '{print tolower($2)}')"
[ -n "$RU_MAC" ] && info "RU MAC in the rendered L1 config: $RU_MAC" || info "no RU MAC rendered yet"
FH=0
for i in $(ls /sys/class/net 2>/dev/null | grep -v lo); do
  [ "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)" = "up" ] || continue
  [ "$(cat "/sys/class/net/$i/mtu" 2>/dev/null)" -ge 8192 ] 2>/dev/null || continue
  ok "fronthaul port up with jumbo MTU: $i"; FH=1
done
[ "$FH" = 1 ] || gap "no interface is up with MTU >= 8192 — check the fronthaul port"
if [ -n "$RU_MAC" ] && ip neigh 2>/dev/null | grep -qi "$RU_MAC"; then
  ok "RU MAC seen in the neighbour table"
else
  info "RU MAC not in the neighbour table (normal: eCPRI is L2, it need not ARP)"
fi

sec "6. Cluster"
for b in kubectl yq; do
  command -v "$b" >/dev/null 2>&1 && ok "$b: $(command -v $b)" \
    || info "$b not on PATH — the scripts fetch it into ~/.local/bin when needed"
done
kubectl get nodes >/dev/null 2>&1 && ok "a cluster is reachable" \
  || gap "no cluster reachable — run ./scripts/3-cluster.sh"

sec "7. Hugepages"
# The DU pod requests 8Gi of 1Gi pages; without them it stays Pending.
HP="$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages 2>/dev/null || echo 0)"
[ "${HP:-0}" -ge 8 ] 2>/dev/null && ok "$HP free 1Gi hugepages" \
  || gap "only ${HP:-0} free 1Gi hugepages — the DU pod requests 8"

printf '\n>> GAP lines above are what stands between this host and a running CU/DU.\n'
