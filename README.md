# Aerial CU/DU on Kubernetes

Deploys a GPU-accelerated 5G RAN: an **OAI CU** and an **Aerial L1 + OAI
DU-High**, split at **F1**, driving an **O-RAN 7.2 radio unit**.

```
                                   5G core (elsewhere)
                                            ▲ N2 / N3
  ┌─────────────────────────────────────────┴────────────────────────┐
  │ this host                                                        │
  │   Deployment/oai-cu ........ RRC · PDCP                          │
  │            ▲ F1-C 38472 / F1-U 2152  (loopback: both hostNetwork)│
  │   Deployment/aerial-cubb                                         │
  │     ├ oai-gnb  DU-High ..... MAC · RLC                           │
  │     │      ▲ nvIPC over /dev/shm                                 │
  │     └ nv-cubb  DU-Low ...... Aerial cuPHY on the GPU             │
  └────────────────────────────┬─────────────────────────────────────┘
                               ▼ eCPRI, O-RAN 7.2 fronthaul
                             O-RU
```

Images are pulled, not built: the L1 binary is inside the Aerial image, the two
OAI images carry the L2. **This is the RAN and nothing else** — no core, no RIC,
no applications on top.

## Run it

Scripts run in filename order. Each says what it changed and what comes next.

```bash
./scripts/1-preflight.sh    # is this host Aerial-ready?        read-only
./scripts/2-fetch.sh        # upstream sources (templates only) → stack/
cp config/site.example.yaml config/site.yaml && $EDITOR config/site.yaml
./scripts/3-cluster.sh      # k3s, pinned off the isolated cores
./scripts/4-render.sh       # site.yaml → 4 configs + 3 ConfigMaps → config/rendered/
./scripts/5-images.sh       # pull the three images
./scripts/6-deploy.sh       # apply, wait for both rollouts
```

Two more, any time: `./scripts/check.sh` says what is still missing before the
CU and DU can start; `./scripts/watch-ue.sh` watches a UE attach and says which
layer broke.

`1-preflight.sh` is not decorative. It checks the two host conditions that
produce almost-undebuggable failures: deep CPU idle states, which ARM does
**not** disable via `idle=poll`, and the PTP wire-timescale vs kernel-TAI-offset
pairing.

Re-rendering alone changes nothing that is running — a ConfigMap's content
changing does not restart a pod. `6-deploy.sh` stamps a hash of the rendered
configs into both pod templates so that it does.

## Verify

Five layers, bottom up. Each can be healthy while the next is not, and a
lower-layer fault always looks like a higher-layer one.

```bash
# 1. L1 accepted the cell: "PHY Cell Id = <your PCI>", error_code=0x0
kubectl exec -n ran deploy/aerial-cubb -c nv-cubb -- \
  bash -c 'grep -E "PHY Cell Id|CONFIG.response" $AERIAL_LOG_PATH/phy.log'

# 2. L1 is serving slots: this count must stay near zero
kubectl exec -n ran deploy/aerial-cubb -c nv-cubb -- \
  bash -c 'tail -n 2000 $AERIAL_LOG_PATH/phy.log | grep -c "Late slot"'
kubectl logs -n ran deploy/aerial-cubb -c nv-cubb --tail=3 | grep "Cell  0 |"

# 3. Radio: on the RU, RX_ON_TIME(_C) counting and TX_TOTAL nonzero
#    (kpi.sh prints per-second RATES, not totals)

# 4. F1: the DU registered with the CU
kubectl logs -n ran deploy/oai-cu | grep -E "F1 Setup|F1AP_SETUP"

# 5. N2: the CU registered with the core — the CU's job, never the DU's
kubectl logs -n ran deploy/oai-cu | grep -E "NGSetupResponse|associated AMF"
```

Anything off: **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — every
failure hit bringing this up on a real DGX Spark and a real RU, each with the
misleading symptom it produces and the actual fix.

## Layout

```
deploy/      the two Deployments. No site data at all, identical on every host
config/      THE DATASTORE: your site.yaml, and everything rendered from it
scripts/     1..6 in run order, plus check.sh and watch-ue.sh
docs/        VERSIONS (read first) · TROUBLESHOOTING · AERIAL
archive/     not part of deploying — old Helm path, build scripts, inspection tools
versions.env pinned versions and the three image refs
stack/       not in git: upstream sources, fetched for their templates
```

`config/site.yaml` is the only file you edit. Everything under
`config/rendered/` is derived from it and overwritten on the next render —
hand-edit it and the cluster's behaviour no longer follows from any input.

**Nothing in `config/` is safe to publish**: fronthaul MAC and VLAN, PCIe
addresses, cell identity, management IPs. It is gitignored, and
`./scripts/guardrails.sh` installs a pre-commit hook that refuses those shapes
as a backstop. See [config/README.md](config/README.md).

## What you need

| | |
|---|---|
| Host | A supported NVIDIA platform — A100/H100/GH200, a converged card, or a Grace-Blackwell system such as GB10. **Aerial cannot run on GeForce.** |
| NIC | ConnectX-6 Dx / ConnectX-7, SR-IOV, fronthaul port at MTU 8192 |
| Timing | PTP grandmaster (G.8275.1) + `ptp4l`/`phc2sys` — 7.2 fronthaul is time-synchronous |
| Radio | O-RAN 7.2 O-RU. Aerial has no RF-simulator mode. |
| Access | NGC account with Aerial access — the containers are not public |
| Core | An existing AMF, reachable at the address in `config/site.yaml` |

Host preparation — driver, kernel, DOCA/OFED, hugepages, CPU isolation, NIC
firmware, PTP — is out of scope: done once per box from NVIDIA's install guide.
Version pairing is the thing that will bite you, so read
[docs/VERSIONS.md](docs/VERSIONS.md) first: the nvIPC/FAPI contract between the
Aerial L1 and the OAI L2 changes between releases, and a mismatched pair fails
at nFAPI handshake rather than at build time.
