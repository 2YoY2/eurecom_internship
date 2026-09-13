#!/usr/bin/env bash
# Read the site PARAMETERS out of a previous deployment and write site/site.yaml.
#
#   ./scripts/30-harvest-params.sh            # search for an old deployment
#   ./scripts/30-harvest-params.sh <cuphy.yaml> <gnb.conf>
#
# This takes VALUES ONLY -- RU MAC, VLAN, eAxC ids, fronthaul timing, cell
# identity, AMF address. It copies no config file, reuses no build, and touches
# nothing it reads. Everything downstream is rendered fresh from the pristine
# upstream templates in stack/ plus these numbers.
#
# Run it once, check the result, then the old tree is no longer needed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/site/site.yaml"
mkdir -p "$ROOT/site"

. "$ROOT/versions.env" 2>/dev/null || true

# Searches must skip our own artefacts. Inventory captures COPY config files, so
# an unfiltered find happily "discovers" a snapshot of a file instead of the
# file, and snapshots of different vintages disagree with each other.
noise() { grep -vE "$ROOT/stack/|/aerial-inventory-|/ran-recipe-|\.bak|\.orig|/site/"; }

CU="${1:-}"; GNB="${2:-}"

# Candidates are ranked, never taken arbitrarily: several generations of the
# same file exist here and they hold DIFFERENT values. Show them all.
if [ -z "$CU" ]; then
  echo ">> cuphycontroller candidates (locally modified only):"
  while read -r f; do
    d="$(cd "$(dirname "$f")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || continue
    git -C "$d" status -s -- "$f" 2>/dev/null | grep -q '^ *M' || continue
    sdk="$(grep -m1 -E '^aerial_sdk_version:' "$f" | awk '{print $2}')"
    printf '     %s\n        sdk=%s  tree=%s\n' "$f" "${sdk:-?}" "$(git -C "$d" describe --tags --always 2>/dev/null)"
    # Rank: the SDK version must match the release we are deploying; among
    # those prefer the profile for this platform (DGX Spark uses the DGX one).
    if [ "$sdk" = "$AERIAL_TAG" ]; then
      case "$f" in *_DGX*) CU="$f" ;; *) [ -z "$CU" ] && CU="$f" ;; esac
    fi
  done < <(find "$HOME" -maxdepth 9 -name 'cuphycontroller_*.yaml' 2>/dev/null | noise)
fi

if [ -z "$GNB" ]; then
  echo ">> gNB config candidates (AMF address shown — they may disagree):"
  while read -r f; do
    amf="$(grep -m1 -oE 'ipv4[[:space:]]*=[[:space:]]*"[0-9.]+"' "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
    d="$(cd "$(dirname "$f")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
    tracked=""; [ -n "$d" ] && git -C "$d" status -s -- "$f" 2>/dev/null | grep -q '^ *M' && tracked="(modified in git)"
    printf '     %s\n        amf=%s %s\n' "$f" "${amf:-?}" "$tracked"
    # A file that git reports as modified inside a real checkout is the one
    # somebody edited; a loose copy is just a copy.
    [ -n "$tracked" ] && [ -z "$GNB" ] && GNB="$f"
  done < <(find "$HOME" -maxdepth 9 -name '*aerial*.conf' 2>/dev/null | noise)
  # Nothing tracked? fall back, but say so.
  [ -z "$GNB" ] && GNB="$(find "$HOME" -maxdepth 9 -name '*aerial*.conf' 2>/dev/null | noise | head -1)" \
                && echo "     (none tracked in git — falling back to the first match)"
fi

echo
echo ">> reading parameters from (nothing is modified):"
echo "   L1 : ${CU:-NOT FOUND}"
echo "   L2 : ${GNB:-NOT FOUND}"
[ -f "${CU:-}" ] || { echo "No modified cuphycontroller config found. Pass one explicitly." >&2; exit 1; }

# --- helpers: read a scalar from the FIRST cell block / from the gNB conf ----
y()  { grep -m1 -E "^[[:space:]]*$1:" "$CU" | sed -E "s/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*//" | tr -d '"'"'"''; }
ya() { grep -m1 -E "^[[:space:]]*$1:" "$CU" | sed -E "s/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*//"; }
g()  { [ -f "${GNB:-}" ] && grep -m1 -E "^[[:space:]]*$1[[:space:]]*=" "$GNB" | sed -E "s/^[^=]*=[[:space:]]*//; s/[;,].*//; s/[[:space:]]*#.*//" | tr -d '"'; }
n()  { local v; v="$(g "$1")"; echo "${v:-0}"; }

# Match a dotted quad, not any digit run: a loose [0-9.]+ picks the "4" out of
# the literal "ipv4" before it ever reaches the address.
AMF="$([ -f "${GNB:-}" ] && grep -m1 -oE 'ipv4[[:space:]]*=[[:space:]]*"[0-9.]+"' "$GNB" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
# Configs on a reused host disagree about the AMF. An operator-confirmed value
# always wins over whatever a stale file says.
if [ -n "${AMF_IP:-}" ]; then
  [ -n "$AMF" ] && [ "$AMF" != "$AMF_IP" ] && echo "   AMF: using confirmed $AMF_IP (config said $AMF)"
  AMF="$AMF_IP"
fi
N2="$([ -f "${GNB:-}" ] && grep -m1 -oE 'GNB_IPV4_ADDRESS_FOR_NG_AMF[^"]*"[0-9./]+"' "$GNB" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
MCC="$(g mcc)"; MNC="$(g mnc)"

cat > "$OUT" <<EOF
# Harvested $(date -u +%Y-%m-%dT%H:%M:%SZ) from a previous deployment.
# VALUES ONLY — no config files, no builds, and nothing else, were carried over.
# Source L1: $CU
# Source L2: ${GNB:-none}
#
# CHECK THESE against the RU's own provisioning before deploying. They are what
# a previous operator arrived at, which is evidence, not proof.

ru:
  vendor: benetel
  model: RAN550
  mac: "$(y dst_mac_addr)"
  vlan: $(y vlan)
  pcp: $(y pcp)
  eaxc:
    ssb_pbch: $(ya eAxC_id_ssb_pbch)
    pdcch:    $(ya eAxC_id_pdcch)
    pdsch:    $(ya eAxC_id_pdsch)
    csirs:    $(ya eAxC_id_csirs)
    pusch:    $(ya eAxC_id_pusch)
    pucch:    $(ya eAxC_id_pucch)
    prach:    $(ya eAxC_id_prach)
    srs:      $(ya eAxC_id_srs)
  timing:
    T1a_max_cp_ul_ns: $(y T1a_max_cp_ul_ns)
    T1a_min_cp_ul_ns: $(y T1a_min_cp_ul_ns)
    T1a_max_cp_dl_ns: $(y T1a_max_cp_dl_ns)
    T1a_min_cp_dl_ns: $(y T1a_min_cp_dl_ns)
    T1a_max_up_ns:    $(y T1a_max_up_ns)
    Ta4_min_ns:       $(y Ta4_min_ns)
    Ta4_max_ns:       $(y Ta4_max_ns)
    Tcp_adv_dl_ns:    $(y Tcp_adv_dl_ns)
    ul_u_plane_tx_offset_ns: $(y ul_u_plane_tx_offset_ns)

fronthaul:
  nic_pcie: "$(y nic)"
  mtu: $(y mtu)

cell:
  band: $(n dl_frequencyBand)
  prb: $(n dl_carrierBandwidth)
  scs: $(n dl_subcarrierSpacing)
  absolute_frequency_ssb: $(n absoluteFrequencySSB)
  absolute_frequency_point_a: $(n dl_absoluteFrequencyPointA)
  phys_cell_id: $(n physCellId)
  nr_cellid: $(n nr_cellid | tr -d 'L')
  pdsch_antenna_ports_xp: $(n pdsch_AntennaPorts_XP)
  pdsch_antenna_ports_n1: $(n pdsch_AntennaPorts_N1)
  pusch_antenna_ports: $(n pusch_AntennaPorts)
  prach_configuration_index: $(n prach_ConfigurationIndex)
  tdd:
    periodicity: $(n dl_UL_TransmissionPeriodicity)
    dl_slots: $(n nrofDownlinkSlots)
    dl_symbols: $(n nrofDownlinkSymbols)
    ul_slots: $(n nrofUplinkSlots)
    ul_symbols: $(n nrofUplinkSymbols)

plmn:
  mcc: "${MCC:-001}"
  mnc: "${MNC:-01}"
  mnc_length: $(n mnc_length)
  tac: $(n tracking_area_code)
  sst: 1

gnb:
  id: "$(g gNB_ID)"
  name: "$(g gNB_name)"

core:
  amf_ip: "${AMF:-0.0.0.0}"
  gnb_n2_ip: "${N2:-0.0.0.0}"

cpu:
  aerial_workers_ul: $(ya workers_ul)
  aerial_workers_dl: $(ya workers_dl)
  aerial_low_priority: $(y low_priority_core)
  aerial_h2d_copy: $(y h2d_copy_thread_cpu_affinity)
  data_core: $(y data_core)
  l2_timer_thread: 15
  l2_message_thread: 16
  oai_gnb: "17-19"
  oai_poll_core: $(n tr_s_poll_core)

aerial:
  mps_sm_ul_order: $(y mps_sm_ul_order)
  pusch_aggr_per_ctx: $(y pusch_aggr_per_ctx)
  prach_aggr_per_ctx: $(y prach_aggr_per_ctx)
  pucch_aggr_per_ctx: $(y pucch_aggr_per_ctx)
  srs_aggr_per_ctx: $(y srs_aggr_per_ctx)

dapp:
  enabled: true
  variant: python
EOF

echo
echo ">> wrote $OUT"
echo ">> review it, especially the RU timing block, then the old tree is dead weight."
echo
grep -vE '^\s*#' "$OUT" | grep -E 'mac|vlan|pcp|T1a|Ta4|amf_ip|gnb_n2_ip|nic_pcie|band|prb|phys_cell' | sed 's/^/   /'
