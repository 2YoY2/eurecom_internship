# Troubleshooting a real Aerial + OAI + O-RAN RU bring-up

Every failure documented here was hit for real bringing up a DGX Spark (GB10)
with Aerial 26-1, OAI `ATB1.0_integration`, and an O-RAN 7.2a RU using this
repo — in this order. Each one produced misleading symptoms; the fixes are now
either automated by the scripts or checked by `1-preflight.sh`, but the
diagnosis trail is worth keeping because the
symptoms will not point you at the causes.

## Where the truth lives

- **L1 log:** `/tmp/phy.log` inside the `nv-cubb` container (wiped each boot —
  anything in it is from the current boot) and/or `$AERIAL_LOG_PATH/phy.log` on
  the host (persists across boots — always check which boot a line belongs to).
- **L2 log:** `kubectl logs -c oai-gnb` (version banner at the top tells you
  what code is actually running).
- **RU counters:** on the RU, `kpi.sh` prints per-second **rates**, not
  totals. The DU restarting must show up as a window of zero rates — if you
  never saw the rates collapse, you sampled the *old* pod.
- After every deploy, verify which pod/boot you are looking at before reading
  any log: `kubectl get pods` (age), then the newest `L1 is ready!` timestamp.

## 1. Cell rejected at CONFIG.request: `pOccaPrms is null`

**Symptoms:** L1 reaches `L1 is ready!`, FAPI link up, then:
`Unknown TLV 0` (dozens), `PHY Cell Id = 0` (your PCI is nonzero),
`Using Min guard Bandwidth -1.0000 kHz`,
`[CUPHY.PRACH_RX] validateStaticParams Invalid input: pOccaPrms is null`,
CONFIG.response `error_code=0x2`. Every config file diffs clean against a
reference set — because the fault is not in any config file.

**Cause:** the L1 was built with the default (`perf`) preset, which sets
`SCF_FAPI_10_04=ON` and gives the TLV header a 32-bit length field. OAI packs
16-bit TLV lengths. The L1 misreads the first TLV's length as megabytes, walks
out of the message, and sees zeros for every remaining TLV.

**Fix:** build cuBB with `--preset 10_02 -- -DSCF_FAPI_10_04_SRS=ON`
(`archive/scripts/31-build-stack.sh` does this).

**Note the guard is gone.** That build script used to be followed by a deploy
that refused an L1 whose CMake cache said `SCF_FAPI_10_04=ON`. The L1 binary now
ships inside the image, so nothing at deploy time can see how it was compiled —
this failure is caught by reading the symptoms above, not by a check.

## 2. Cell starts, every slot errors: `Late slot error` (0x34)

**Symptoms:** CONFIG/START succeed, then ~2000/s of
`send_slot_error_indication: Late slot error` with
`tick_received: tick_err -80..-130`. The DU transmits nothing; the RU counts
zero packets. Note: `tick_err` is **nanoseconds** — those ticks are ~100 ns
*early*, i.e. essentially perfect.

**Cause:** an Aerial 26.1 bug. `nv_phy_module.cpp` compares the signed
`tick_err` against an unsigned threshold; with `tick_generator_mode: 0`
(poll) ticks fire slightly early, the negative value wraps, and every slot is
declared late. Mode 0 cannot work on this release — reference config bundles
that carry it were not validated on 26.1.

**Fix:** `tick_generator_mode: 1` (sleep mode; the renderer's default —
`aerial.tick_generator_mode` in `site.yaml`).

## 3. Mode 1 needs the host's deep idle states off — and ARM ignores `idle=poll`

**Symptoms:** with mode 1, tick wakeups must land within 15 µs of the slot
boundary. Deep CPU idle states cost 40–450 µs of exit latency, producing
intermittent or constant late slots.

**Cause:** x86-flavored host prep sets `idle=poll` / `processor.max_cstate=0`
on the kernel command line. Both are **silently ignored on aarch64** — the LPI
idle states stay enabled. The cmdline looks right; sysfs tells the truth.

**Fix:** disable states with >10 µs exit latency on the isolated cores:
`for s in /sys/devices/system/cpu/cpu{<isolated>}/cpuidle/state*; do
[ "$(cat $s/latency)" -gt 10 ] && echo 1 > $s/disable; done` — and persist it
with a boot-time unit, because sysfs resets on reboot. `1-preflight.sh` fails
when deep states are enabled on isolated cores.

## 4. RU classifies 100% of C-plane as EARLY and never radiates

**Symptoms:** the DU transmits (RU `RX_TOTAL` counting), but every C-plane
packet lands in `RX_EARLY_C`, none on-time; the RU sends no uplink
(`TX_TOTAL 0`); the DU's UL slots go "unhealthy" after multi-ms waits. PTP is
locked at ns level on both ends, RU provisioning (MAC/VLAN/TDD/frequency) all
verified. Changing T1a windows by hundreds of µs changes nothing; toggling
`accu_tx_sched_disable` changes nothing — the packets are not early by
microseconds but by *frames*.

**Cause:** PTP **timescale** mismatch. Aerial numbers GPS frames as
`CLOCK_REALTIME + kernel_TAI_offset − (GPS epoch + 19 s)`. The RU takes the
PTP wire time as TAI, per O-RAN. If the PHC (what goes on the wire when this
host is the RU's PTP master) carries UTC (phc2sys `-O 0` with a UTC system
clock) while the kernel TAI offset is 37 s, the two frame timelines sit 37 s
apart. 37 s is an exact multiple of the 10 ms frame, so slot *phase* stays
perfectly aligned — nothing looks corrupt — while the frame *number* shifts by
3700 ≡ 116 frameIds (mod 256). The RU bins every C-plane packet as early and
discards it. This is close to undebuggable from the symptoms alone: compare
`date -u`, the kernel TAI offset (`CLOCK_TAI − CLOCK_REALTIME`), and
`phc_ctl <fh-port> cmp` across DU and RU instead.

**Fix:** make the timelines consistent — either of these pairs works, mixing
them does not:
- wire = TAI: step the PHC (`phc_ctl <fh-port> adj 37`), phc2sys `-O -37`
  (system clock stays UTC), kernel TAI offset 37. The telecom-correct setup.
- wire = UTC: phc2sys `-O 0` **and** kernel TAI offset 0 (lab-only; absolute
  GPS time is off by 37 s but DU and RU agree).

`1-preflight.sh` fails on an inconsistent combination.

## 5. Benign on DGX Spark: eCPRI flexparser warnings

`mlx5_net: Dynamic flex parser is not supported` /
`eCPRI parser not supported ... retrying without eCPRI` on every start is an
acknowledged NVIDIA firmware limitation of the DGX-Spark CX-7 configuration.
The L1 falls back to MAC-based steering, which demonstrably suffices: with the
issues above fixed, the RU receives 100% on-time on both planes and uplink
flows. Do not chase these warnings; do check for fixed NIC firmware
eventually. Accurate TX scheduling also works on this NIC — it was explicitly
exonerated during this debugging.

## 6. UE attaches but has no internet

Registration proves N1/N2 and the radio. Data is a different path entirely:
GTP-U over N3 to the UPF, then the UPF's N6 side outward. The causes look
identical from the UE, so capture all layers at once during one attach:

```bash
./scripts/watch-ue.sh        # then attach the UE; Ctrl-C when done
```

It records the gNB log, the N3 capture (UDP 2152) and the L1's PRACH activity,
then prints which layer broke:

- **No PDU session in the gNB log** — nothing was ever built to carry data.
  The core decided that: subscriber not provisioned for the requested DNN,
  slice mismatch against what the gNB advertises, or the SMF has no UPF for
  that DNN. The failure cause code, if any, is in the captured log.
- **Uplink packets only** — the UE's traffic leaves and the UPF never answers:
  UDP 2152 filtered in one direction, or no route back to the gNB's NGU
  address. Note that SCTP being permitted says nothing about GTP-U.
- **Traffic both ways** — the RAN and N3 are fine; the fault is past the UPF.
  Check DNS first (`ping 8.8.8.8` vs `ping google.com` from the UE — reaching
  the IP but not the name means the SMF handed out an unreachable resolver),
  then MTU (`ping -M do -s 1400`; GTP overhead makes a 1500-byte UE MTU
  unusable), then N6/NAT for the UE pool.

## 7. UE attaches erratically; no uplink; preambles "detected" in noise

**Symptoms:** the RU is healthy (PTP locked, on-time C/U-plane, transmitting
uplink packets, receiver at thermal noise) and the cell is up, but: the gNB
logs `no free RA process` for dozens of RANDOM preamble indices per second;
the UE attaches only occasionally and then loops through RRC re-establishment;
`pucch0_DTX` and `ulsch_DTX` climb without bound; DL BLER approaches 1.0 with
everything retransmitting to the last HARQ round. That last one is a
consequence, not a cause -- with no HARQ-ACK arriving, every transport block
retransmits and is counted an error.

**Cause:** the DU's PRACH eAxC ids do not match the RU's. The DU listens on
ports the RU never transmits on, so cuPHY correlates empty buffers and finds
"preambles" in noise -- which is also why attach sometimes works: with false
detections spraying across all 64 indices, one eventually matches the real UE's
preamble in the right occasion, and the RA proceeds by luck. Meanwhile the RU's
real PRACH arrives on ids the DU has assigned to SRS, so PRACH gets processed
as SRS and can stall the uplink slot.

**Fix:** read the eAxC table off the RU rather than from any config file. On a
Benetel RANx50 it is `/etc/eaxc_X_Yt.xml` (X = software generation, Y = the
transmit mode from `mimo_mode` in `/etc/ru_config.cfg`), and PRACH sits on
ru-port **8-11**, not 4-7 -- the CUS-Plane user guide says explicitly that the
O-DU must be configured to match. Set `ru.eaxc.prach` accordingly and move
`ru.eaxc.srs` off those ids (the RU defines no separate SRS eAxC; SRS rides the
uplink ids and is separated by section id).

## 8. Fronthaul timing: use the vendor's O-DU delay profile, not a harvested one

Every O-RAN RU vendor publishes an "O-DU delay profile" table, and it varies
with RU firmware version AND with the DU implementation. Benetel's RANx50 L1
interface specification tabulates, for V2.0 firmware driving a FlexRAN-style DU
(the column Aerial matches): `T1a_cp_dl 419-470`, `T1a_cp_ul 390-405`,
`T1a_up 294-345`, `Ta4 50-331` microseconds -- and its release notes call out
that this firmware "requires tighter control of the DU t1a delay parameters".

NVIDIA's shipped `cuphycontroller` templates already carry real profiles.
Overwriting them with numbers harvested from an older deployment (e.g.
`T1a_min_cp_dl` 419000 -> 7600, `T1a_min_cp_ul` 390000 -> 36000) makes the DU
transmit outside the window the RU accepts, and the RU simply discards what it
cannot use. Leave a value at 0 in `site.yaml` and this repo's renderer keeps the
template's value, which is the safer default.

## 9. Traps that cost real time

- **Stale L2 image:** an `oai-gnb-aerial:latest` left over from an earlier
  setup deploys silently and speaks a different FAPI encoding. Pin the image by
  digest or by a real tag in `versions.env` rather than `:latest`, and check
  what you are about to run with `docker image inspect`. This is the reason
  `5-images.sh` prints which images exist only in the local store.
- **Configs changed but pod didn't restart:** rendered configs arrive via
  hostPath, which Helm can't hash. The deploy stamps a config hash into the
  pod annotations; without it a re-render "deploys" the old config forever.
  The L1 *binary* is also a hostPath — after rebuilding the L1, `kubectl
  rollout restart` is still required (the hash doesn't cover it).
- **Readiness lies once:** the probe greps for `L1 is ready!` and can match a
  previous boot's line in the persistent host log. Trust the current boot's
  log, not the READY column.
- **`nc` cannot probe SCTP.** A TCP probe of an AMF's port 38412 fails against
  a perfectly healthy AMF. Probe with a real SCTP socket
  (`python3` + `socket.IPPROTO_SCTP`) before blaming the core network.
- **Two vendor configs, one truth:** config bundles and filenames tell you
  what someone once edited, not what was ever validated. Both showstopper bugs
  above (FAPI preset, tick mode) were present in a "known-good" reference set.

## The meta-lesson

Every one of these produced evidence that looked like someone else's fault —
a vendor PHY bug, a radio timing defect, NIC firmware. Ruling out two knobs
with experiments does not rule *in* the third party: before declaring
yourself blocked, enumerate every mechanism consistent with **all** the
observations and find the experiment that discriminates between them. A
constant symptom that survives config changes usually means the mismatch is in
identity or timelines (clocks, epochs, numbering) — not in the hardware.
