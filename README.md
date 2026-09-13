# eurecom_internship

Work on a disaggregated 5G RAN: NVIDIA Aerial for the physical layer, OAI for
everything above it, deployed on Kubernetes across three machines.

## What is here

    infrastructure/V-RAN/    Deploying the RAN on Kubernetes

## The deployment

Three components, three machines, one cluster:

| | runs | on |
|---|---|---|
| **CU** | OAI RRC/PDCP/SDAP | its own host |
| **DU-High** | OAI MAC/RLC (the L2) | a second host, different architecture |
| **DU-Low** | NVIDIA Aerial cuPHY (the L1) | a GPU host |

The DU-High and DU-Low are normally the same machine: the L2 reaches the L1
through shared memory, and shared memory does not cross a machine boundary.
Here they are separate hosts, and the L2 drives the L1 over SCF FAPI carried on
nvIPC's DPDK transport, across the network.

## What is deliberately not here

No RAN configuration. Cell identity, PLMN, the CU/RIC/core addresses, peer MACs,
PCI addresses and fronthaul parameters are site data: they live in ConfigMaps
supplied per deployment, never in this repo and never inside the images.

## Not yet here

`preparation/` -- host prerequisites (hugepages, isolated cores, SR-IOV, PTP,
the GPU driver), cluster creation and the preflight checks. Until it exists,
this repo deploys onto a system that is already prepared.
