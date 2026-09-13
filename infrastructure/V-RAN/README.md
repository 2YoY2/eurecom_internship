# V-RAN

Deploys the CU, DU-High and DU-Low onto an existing Kubernetes cluster.

    deploy/10-du-low.yaml     Aerial cuPHY, the L1.  Pins to yoy.ran/role=du-low
    deploy/11-cu.yaml         OAI RRC/PDCP/SDAP.     Pins to yoy.ran/role=cu
    deploy/12-du-high.yaml    OAI MAC/RLC, the L2.   Pins to yoy.ran/role=du-high

    scripts/5-images.sh       Make sure the three images are on the nodes
    scripts/6-deploy.sh       Apply the manifests, in the order that works

Scripts 1-4 are host preparation and cluster creation. They are not here yet;
see `preparation/` in the root README.

## Run

    ./scripts/5-images.sh
    ./scripts/6-deploy.sh

## What must already exist

This repo carries the deployment mechanics and nothing else. Before the first
deploy the system needs:

**The three ConfigMaps**, in the target namespace. They hold the site's RAN
configuration and are deliberately absent from this repo:

| ConfigMap | keys |
|---|---|
| `l1-config` | `cuphycontroller_site.yaml`, `l2_adapter_config_site.yaml`, `nvipc_l1_dpdk.yaml` |
| `oai-cu-conf` | `gnb.conf` |
| `oai-du-high-conf` | `gnb.conf`, `nvipc.yaml` |

`6-deploy.sh` checks for them and stops with the `kubectl create configmap`
command rather than deploying something broken.

**The images on each node.** All nodes run k3s with `--docker`, so the node's
local Docker store is the image store and no registry is involved.

**Node labels**, because the GPU, the fronthaul NIC and the SR-IOV VF are
properties of particular machines and architecture alone does not identify them:

    kubectl label node <gpu-host>     yoy.ran/role=du-low
    kubectl label node <l2-host>      yoy.ran/role=du-high
    kubectl label node <cu-host>      yoy.ran/role=cu

**Host preparation**: hugepages, isolated cores, the SR-IOV VF bound to
`vfio-pci`, PTP, the GPU driver.

## Ordering

`6-deploy.sh` applies CU, then DU-Low, then DU-High, and waits for the DU-Low to
report ready before starting the DU-High. This is not cosmetic: the L1's nvIPC
connect handshake is single-shot, so a DU-High that dials before the L1 is
listening blocks forever and the L1 has to be restarted before the next attempt.

## Configuration that is not in a ConfigMap

Worth knowing, because it is invisible from the manifests:

- **Compile-time.** The nvIPC VLAN id and the connect count are `#define`s in
  the binaries, with no runtime negotiation and no config field. Both ends of
  the FAPI link must be built to agree.
- **Image environment.** The L1 needs `CUDA_MODULE_LOADING=EAGER`. Since CUDA
  11.7 the default is lazy, which loads a kernel module on first launch -- inside
  a slot, where it blows the L1's 8 ms watchdog.
- **Host state.** Node labels, hugepages, the VF and its VLAN, isolated cores.
