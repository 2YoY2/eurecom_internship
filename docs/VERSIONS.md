# Verified version matrix — Aerial + OAI + dApp on GB10 (DGX Spark)

Researched 2026-08-22. Pins live in [`versions.env`](../versions.env); override
per-deployment values in `config/versions.env`.

## The validated set

| Layer | Version | Notes |
|---|---|---|
| Aerial CUDA-Accelerated RAN | **26.1.0**, container tag `26-1-cubb` | Released 2026-06-15. Source tree tag `26.1.1`. |
| Aerial Testbed (ATB) | **1.0** (April 2026) | The release that adds DGX Spark support. |
| Aerial Sample Apps (dApp framework) | **1.0** | E3 interface + PRB-Power reference dApp. |
| OAI L2/L3 | branch **`ATB1.0_integration`** | From `gitlab.eurecom.fr/oai/openairinterface5g`. Pairs with cuBB 26-1. |
| GPU driver | **590.48.01** (OpenRM) | CUDA **13.1.1**. |
| Kernel | **6.17.0-1014-nvidia** | |
| DOCA / OFED | **3.2.1** / **OFED-internal-25.10-1.7.1** | |
| linuxptp | **4.2** | Needed for dual-port PTP. |
| Hugepages | `hugepagesz=1G hugepages=24` | |
| CPU isolation | `isolcpus=managed_irq,domain,4-19 nohz_full=4-19 rcu_nocbs=4-19` | Cores 0–3 for the OS, 4–19 isolated. |
| NIC | ConnectX-7, ports named `aerial00`–`aerial03` | Fronthaul port needs MTU 8192. |

**Do not mix rows.** The nvIPC/FAPI contract between the Aerial L1 and the OAI L2
changes between releases. A mismatched pair does not fail at build time — it
fails later at nFAPI handshake, which is a much harder thing to debug.

**The L1 build preset is part of the contract.** cuBB must be built with
`--preset 10_02 -- -DSCF_FAPI_10_04_SRS=ON -DENABLE_CONFORMANCE_TM_PDSCH_PDCCH=OFF`
(what `archive/scripts/31-build-stack.sh` passes). The default `perf` preset sets
`SCF_FAPI_10_04=ON`, which changes the TLV header from 16-bit to 32-bit length
fields — OAI always writes 16-bit ones. A default-built L1 misreads the first
CONFIG.request TLV's length as megabytes, walks out of the message, logs
`Unknown TLV 0` for every remaining TLV, and rejects the cell with
`[CUPHY.PRACH_RX] ... pOccaPrms is null` — an error that reads like PRACH
misconfiguration and diffs clean against every config file. (Verified against
`scf_fapi_tl` in Aerial 26.1.1 and `pack_tl` in OAI `ATB1.0_integration`;
observed 2026-08-23 as `numTLVs=38` + 37 × `Unknown TLV 0`.)

NIC firmware settings required for eCPRI flow steering and accurate TX
scheduling: `FLEX_PARSER_PROFILE_ENABLE=4`, `PROG_PARSE_GRAPH=1`,
`REAL_TIME_CLOCK_ENABLE=1`, `ACCURATE_TX_SCHEDULER=1`, `CQE_COMPRESSION=1`.

## The honest answer on Benetel RAN550 + GB10

**There is no NVIDIA-validated pairing of a Benetel RAN550 with a DGX Spark.**
What actually exists is three separate things:

1. **NVIDIA validates DGX Spark/GB10** with Aerial 26-1 — but its published RU
   list for the testbed names **WNC 1220 / WNC 3210** and **Foxconn** units.
   Benetel does not appear in it.
2. **Benetel validates the RAN550 with Aerial L1 + OAI L2/L3** — but through
   **OAIBOX**, their own integrated product, not on a DGX Spark.
3. The RAN550 is a standard **O-RAN 7.2a** indoor RU (n78/n79), and is well
   documented against other stacks (srsRAN publishes a RAN550 config guide).

So the fronthaul split is standard and there is no reason it cannot work — but
you are the integrator for this specific combination, not a follower of a
validated recipe. Concretely, the RU-facing parameters have to be derived
locally: fronthaul MAC/VLAN, eAxC ID assignment, PRACH/SRS section IDs,
compression, and the TDD pattern the RU is provisioned for.

This is reinforced by NVIDIA's own gap: **the public 26.1.0 release ships no
DGX Spark `cuphycontroller` or `l2_adapter` YAML**, so operators derive those
locally regardless of RU. That is almost certainly why the Aerial tree on an
already-working box shows those two files as locally modified — start from
whichever vendor template is closest and edit, which also means **a config
filename tells you nothing about the RU actually attached**.

## DGX Spark / GB10 specifics

- **No MIG.** GB10 does not support MIG partitioning, so **CUDA MPS is the only
  way** to share the GPU between the L1 and a dApp. The `mps_sm_*` keys in
  `cuphycontroller` config are how the SM budget gets split (PUSCH/PDSCH get the
  large shares). The ISAC paper measures this exact configuration on DGX Spark.
- **Single cell only** in ATB 1.0 on DGX Spark.
- **Unified memory**, so `nvidia-smi` reports `Memory-Usage: Not Supported`.
  That is normal on this platform, not a fault.
- **GPUDirect RDMA is disputed.** A community DGX Spark automation repo reports
  it unsupported, which would block the standard cuPHY fronthaul path; NVIDIA
  nonetheless lists ATB as supported on DGX Spark. Treat as unresolved and
  verify on the box before assuming either way.

## dApp framework (from the ISAC paper)

The reference architecture places an **E3 Agent** inside the Aerial DU-Low and an
**E3 Manager** in the dApp container, communicating over **ZeroMQ** with bulk
data passed through **POSIX shared memory** in pinned host memory. The
**Aerial Data Lake** captures PHY data via a ping-pong double buffer into
ClickHouse. The reference **PRB Power** dApp consumes a `[4, 14, 273, 12, 2]`
FP16 I/Q tensor — one 100 MHz uplink slot at 30 kHz SCS — and the framework adds
about **150 µs** of overhead with the Triton C API backend.

Note the paper's own measurements are on a **Foxconn CBRS RU at 3.65 GHz**, not
a Benetel, and it states plainly that DGX Spark cannot do the MIG-isolated
configuration — only shared-GPU via MPS.

## Sources

- [Aerial CUDA-Accelerated RAN — NGC container](https://catalog.ngc.nvidia.com/orgs/nvidia/aerial/containers/aerial-cuda-accelerated-ran)
- [Installing Tools on NVIDIA DGX Spark System](https://docs.nvidia.com/aerial/cuda-accelerated-ran/latest/install_guide/installing_tools_spark.html)
- [Aerial Testbed release notes](https://docs.nvidia.com/aerial/testbed/latest/text/release_notes.html)
- [Aerial Testbed installation guide](https://docs.nvidia.com/aerial/aerial-ran-colab-ota/current/text/installation_guide/manual_install.html)
- [Aerial 26-1 / ATB 1.0 / Sample Apps 1.0 announcement](https://github.com/NVIDIA/aerial-framework/discussions/9)
- [NVIDIA/aerial-sample-apps](https://github.com/NVIDIA/aerial-sample-apps)
- [OAI Aerial FAPI split tutorial](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/develop/doc/Aerial_FAPI_Split_Tutorial.md)
- [Benetel: NVIDIA & OAI integration via OAIBOX](https://benetel.com/nvidia-oai-integration-is-here-via-oaibox/)
- [Benetel RAN550 product page](https://benetel.com/ran550/) · [datasheet](https://cdn.prod.website-files.com/665f1b4b8eba5127ca955ccd/66f55ffe2c1bda1b594f04a4_RAN550_Datasheet_v1.9.pdf)
- [srsRAN: Benetel RAN550/RAN650 configuration](https://docs.srsran.com/projects/project/en/latest/tutorials/source/oranRU/source/rus/r550.html)
- [ai-ran-dgx-spark (community DGX Spark automation)](https://github.com/rcbarke/ai-ran-dgx-spark)
- Villa, Belgiovine, Hedberg, Polese, Dick, Melodia, *Programmable and GPU-Accelerated Edge Inference for Real-Time ISAC on NVIDIA Aerial Testbed*, [arXiv:2512.06493](https://arxiv.org/abs/2512.06493)

## GB10 and the NVIDIA Kubernetes device plugin

**The device plugin cannot run on GB10.** It builds its device map by querying
per-device memory, and on a unified-memory part NVML answers `Not Supported`,
so the DaemonSet crash-loops:

```
error building device map: error visiting device: error building Device:
error getting device memory: Not Supported
```

`nvidia-smi` reports the same thing as `Memory-Usage: Not Supported`. That is
the platform being unified-memory, not a fault.

Consequence: the node never advertises `nvidia.com/gpu`, so any Pod requesting
one stays `Pending` forever with `Insufficient nvidia.com/gpu`.

**The fix is not to need it.** Configure nvidia as Docker's default runtime
(`nvidia-ctk runtime configure --runtime=docker --set-as-default`) and the GPU
is injected into every container, with `NVIDIA_VISIBLE_DEVICES` selecting what
the container sees. A device plugin exists to *ration* GPUs between competing
pods; a dedicated RAN node with one GPU and one DU has nothing to ration.

The chart therefore defaults to `l1.requestGpu: false` and passes the GPU
through the runtime. Set it to `true` only on a discrete-GPU host where several
workloads compete and the plugin can actually start.

## CPU pinning: why Aerial fights the Kubernetes CPU manager

Aerial pins its threads to **absolute core ids** read from `cuphycontroller`'s
YAML (`workers_ul`, `workers_dl`, `dpdk_thread`, `low_priority_core`,
`data_core`). If a core is outside the container's cpuset, `sched_setaffinity`
returns `EINVAL` and the L1 aborts with:

```
[FH.LIB] Exception! Error setting CPU affinity mask: Invalid argument
```

This looks like a fronthaul fault. It is a cgroup fault.

The Kubernetes CPU manager cannot solve it. Its static policy grants *exclusive*
cores to Guaranteed pods, but **the kubelet chooses which cores** — it has no
way to honour "core 5 and 6 specifically". An app that hardcodes core ids and a
scheduler that assigns them arbitrarily cannot agree.

So the DU pod is deliberately **Burstable** (memory request, no cpu request):

- no cpu request → the CPU manager ignores the pod and never rewrites its cpuset
- the pod's cpuset must simply *include* the cores the YAML names
- isolation still comes from `isolcpus` at boot, not from Kubernetes

The corollary is that `kubepods.slice` must be allowed those cores. A host that
previously ran the L1 outside Kubernetes may fence kubepods away from them — see
`3-cluster.sh`, which detects and widens that. Excluding them is redundant
anyway: `isolcpus` already stops the scheduler placing ordinary threads there,
so only a deliberate `sched_setaffinity` ever lands on an isolated core.

## Known blocker: eCPRI flex parser on DGX Spark CX-7

The L1 reaches the fronthaul and then reports:

```
mlx5_net: Dynamic flex parser is not supported for device <fronthaul-bdf>
[FH.PEER] eCPRI parser not supported on NIC <fronthaul-bdf>, retrying without eCPRI
```

**This is a known NVIDIA firmware defect specific to the DGX Spark CX-7, not a
configuration error.** NVIDIA staff on the Aerial developer forum: *"We also
know about this flexparser error, which causes several issues. This error occurs
only on the DGX Spark-specific CX-7 configuration."* They state the upcoming NIC
firmware fixes it, with no release date announced.

Affected firmware: **28.47.1088**, PSID **NVD0000000087**.

The five `mlxconfig` settings are still required and are *not* the problem —
verify them, but having them correct does not avoid this. `mlx5_flex_parser_
ecpri_alloc()` returns `-95` (ENOTSUP) regardless.

Note the failure mode: the L1 **degrades rather than aborting**. It logs the
warning, retries without eCPRI, and keeps running, so it looks alive.

Nothing on the Kubernetes side changes this. Track the forum thread and the
NIC firmware release; everything else in this repo is unaffected and ready.
