# Verification plan and implemented checks

The portable ModelSim bench uses a byte-addressable responder and an
independent copy oracle. For each scenario it initializes a deterministic
pseudorandom source and
destination memory image, snapshots the original bytes, computes the
expected destination from the programmed addresses and length, then compares
all 32,768 bytes after completion. The oracle does not read DUT state,
counters or burst-buffer contents. It also tracks **accepted** AR, R, AW,
W and B handshakes separately, checking every address, burst length and
data-beat progression against the programmed request.

| Requirement | Check in `tb/tb_dma_portable.sv` |
| --- | --- |
| Zero length and rejected requests issue no memory traffic | `zero`, misalignment, overlap, too-long and overflow cases; handshake count deltas |
| Byte-accurate copy and guard regions | Full byte-memory comparison after every case |
| 1–16 beat INCR bursts and 4 KiB limits on both sides | AR/AW monitors and source/destination boundary cases |
| Partial final beat | 1-, 9-, 129-byte and seeded copies; accepted strobe writes and byte-memory oracle |
| Read and write response errors | Injected `RRESP=SLVERR` and `BRESP=SLVERR`; status/code and memory comparisons |
| Completion/interrupt/acknowledge | Status and error-code readback plus interrupt clearing in every case |
| Busy write/start/ack policy | 4096-byte case attempts all three while active and expects `SLVERR` |
| AXI4-Lite independent AW/W | Address-first and data-first register writes |
| AXI4 output stability under stalls | Passive AW, AR and W payload-stability monitors |
| Independent AXI4 AW/W completion | AWREADY waits for WVALID; one-beat W-before-AW acceptance; independent stalls and exactly one B response |
| Reset in one shared domain | Reset during first accepted read burst, then status and memory check |
| Liveness in test environment | Finite per-case and global watchdogs plus a 120-second wrapper timeout |

Directed lengths include 0, 1, 8, 9, 16, 24, 128, 129, and 4096 bytes.
Five additional deterministic cases use LCG seed `0x28A6BEEF` to vary
lengths, aligned addresses, and bus stalls. The responder changes
`AWREADY`, `ARREADY`, `WREADY`, `RVALID`, and `BVALID` on independent
cycle schedules. These are reproducible variations, not measured functional
coverage.

The source responder may write an accepted burst before returning a write
error. The oracle expects that explicitly. A read error on the first burst
stops before the corresponding destination write. The testbench does not
cover every legal AXI4 timing combination, multi-ID traffic, interconnect
arbitration, descriptors, or hardware behavior.

Run from a clean checkout with ModelSim 2020.1 executables on PATH:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_regression.ps1 -OutputDir <new-output-directory>
python scripts/check_provenance.py
```

The wrapper requires a fresh output directory, compiles the bounded RTL and
bench, enforces a wall timeout, checks process exit and simulator fatal/error
markers, requires `$finish` and zero simulator errors, and records JSON.
Disposable old-RTL and source-address-aliasing faults are used separately to
verify that the new directed test and independent oracle exit nonzero.
