# Ayyur

Per-actor wireless sensing on the RAN edge. A dApp beside the L1 separates
uplink CSI into per-actor latents; an xApp on the RIC sends actor fingerprints
down and receives those latents up, over a custom E2 service model
(**E2SM-AYYUR**, RAN function 149). Raw CSI never leaves the gNB.

This directory holds only what attaches Ayyur to the V-RAN deployment. The
project itself -- the dApp, the cascade, the service model sources, the models
-- lives in its own repository.

    attach-dapp.sh    attach/detach the dApp against a running V-RAN

## Where each piece runs

The split is forced by the interfaces, not by preference:

| piece | host | why there |
|---|---|---|
| dApp + cascade | **DU-Low host** | E3 is a shared-memory segment (`/e3_ran_buffers`) plus localhost TCP. It cannot cross a machine. |
| E2 agent (E2SM-AYYUR) | **DU-High host** | the agent is part of OAI's MAC/RLC, which is where the E2 interface lives |
| xApp + near-RT RIC | **CU host** | ordinary E2 over SCTP |

So the dApp is pinned to one machine and the agent to another, and the two are
joined by a ZMQ bridge that used to be localhost and now crosses the network.

## Data flow

    RU --7.2--> [DU-Low: cuPHY]
                     |  E3: /e3_ran_buffers (shm) + localhost TCP
                     v
                 [dApp] --ZMQ :5570--> [cascade]
                                            |  binds :6001 (control) and :6002 (latents)
                                            |  ZMQ, across the network
                                            v
                                    [DU-High: OAI MAC/RLC + E2 agent]
                                            |  E2 / SCTP, RAN function 149
                                            v
                                    [near-RT RIC + xApp]

The agent **connects out** to the dApp; the dApp binds. That is why the dApp's
host needs no inbound configuration beyond the two ports being reachable.

## Requirements on the DU-High

The E2 agent must carry the service model and be told where the dApp is. Both
are already in `../V-RAN/deploy/12-du-high.yaml`:

    AYYUR_DAPP_CTRL_EP     tcp://<du-low-host>:6001   RIC -> dApp (enroll/release)
    AYYUR_DAPP_LATENT_EP   tcp://<du-low-host>:6002   dApp -> RIC (latent reports)

and `libayyur_sm.so` must be present in the image under `/usr/local/lib/flexric/`,
which the E2 agent loads at runtime from its configured `sm_dir`.

## The GPU rule

The cascade shares one GPU with the L1. There is no MIG on this part, so CUDA
MPS is the only isolation, and **creating an MPS client context stalls all GPU
work for tens of milliseconds**. While the cell is idle that is harmless. With a
UE attached it is fatal: every cuPHY watchdog trips at once and the L1 aborts.

    Attach only while the cell is idle. Never restart the cascade under traffic.

`attach-dapp.sh` refuses to attach when it sees a UE, and warns on detach.

Measured steady-state cost, capped to 12 of 48 SMs at below-normal priority:
**~26 late slots/min against a baseline of 0**, uplink unaffected. Uncapped it
is 50-100 late slots/min and the uplink collapses.

## Usage

    ./attach-dapp.sh status     # what is attached
    ./attach-dapp.sh attach     # start dApp + cascade (refuses if a UE is up)
    ./attach-dapp.sh detach     # stop them

Run it on the DU-Low host. `AYYUR_DIR` points at the Ayyur checkout
(default `~/ayyur`).
