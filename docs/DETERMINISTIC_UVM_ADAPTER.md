# Separate deterministic DMA UVM/SVA adapter

The reusable environment is implemented in AMBA-Protocol-Verification, with
the real RTL in this repository pinned to **`a2d3d57edaa9eb441f3289bf5320f4df2f074144`**. This documentation PR
does not change RTL, the existing 40-case portable runner, source provenance,
licences, attribution or historical evidence.

## Corrected tested environment and result — 10 November 2026

Environment and runner: **`e6fbb510aa88b1f5aa8a7cc04926eeefbfb5be4d`**; inventory:
`e6fbb510aa88b1f5aa8a7cc04926eeefbfb5be4d`; DUT stays `a2d3d57edaa9eb441f3289bf5320f4df2f074144`.
[Immutable corrected evidence](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/08bde7496be07c83c3acd546ecef6bc7e6cc40b5/reports/dma-uvm-corrective-2026-11-10/SUMMARY.md) records a clean detached GitHub run:
**47/47 required PASS**, aggregate and wrapper exit 0. The named inventory
comprises 30 standalone assertion controls (one legal, 29 expected negatives),
seven functional groups with 68 scenarios, and ten fault qualifications. All ten
fault children exit 1 for their intended diagnostic; unrelated crashes, tools,
compile errors and timeouts cannot qualify a fault.

The old oracle falsely rejected seven legal modified-inactive-lane tail cases;
the corrected expected-mask data oracle passes all seven, including stable
stalled partial writes, with source/destination/guard memory correct. Exact
WSTRB/LAST/progression and full offered-payload stability remain checked.
Old CSR tests missed both idle partial-strobe and busy configuration side effects
while SLVERR was returned. New protected-state readbacks detect both with
`CSR_READ` and child exit 1. Every rejected write is followed by reads of
SRC/DST/LENGTH and status/error/control before overwrite/reset. The busy
responder stays paused until those reads finish, then completes normally.
Disposable mutation source/diff/hashes are separate from the pristine DUT lock;
no mutation is committed into this repository's production RTL.

The final run recorded 150,777 comparisons,
90 commands = 87 terminals + 3 reset cancellations,
and 102 complete rejected-write readback checkpoints.
Burst/beat/response relationships are reconciled in raw JSON. These are separate
units, not functional coverage. Simulator: Questa Altera Starter FPGA Edition-64
2025.2, runtime `QUESTA_UVM-1.2.3`, seed `0x28A6BEEF`; sessions are serial.

The [original 43-substep report](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/3d17e3bed5396c828a76be13ff18229e39dea740/reports/dma-uvm-2026-11-09/SUMMARY.md)
and its old evidence are preserved. The existing portable result (40 cases /
1,352,655 checks) and 11-file provenance remain applicable; relevant inputs
did not change and those checks were not rerun in this corrective pass.

## Adapter and supported contract

The [public-pin adapter and requirements guide](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/08bde7496be07c83c3acd546ecef6bc7e6cc40b5/docs/DETERMINISTIC_DMA_UVM.md) connect a UVM
AXI4-Lite CSR initiator and a genuinely early-W-buffering AXI4 memory responder
to the existing ports. The scoreboard has separate CSR semantics and an
independent sparse 32-bit byte model. AW/W acceptance, read/write beats,
terminal outcomes, acknowledgements, rejected CSR writes and reset cancellations
are counted separately. Test-only address/data/strobe/duplicate/progress shims
are confined to AMBA; none changes this DUT.

This is one programmed command, fixed ID zero, 64-bit eight-byte INCR data,
one read burst then its write, at most 16 beats, length 0-4096, aligned nonzero
source/destination and low-lane tail strobes. Both 4 KiB boundaries and widened
top-of-address-space ends are checked. The CSR table and busy/error/ack policy
are documented in the guide. Wrong RID/BID and early/missing RLAST are
reset-isolated malformed-target tests, separate from legal error responses.

Clarification of `docs/SPECIFICATION.md`: normal-length read errors drain the
planned burst; early RLAST ends the read early and missing final RLAST ends it
at the planned count. Arbitrary malformed streams are not guaranteed to drain.
Recovery uses shared reset and a subsequently well-behaved target. Reset
cancels protocol obligations without undoing already committed modeled writes.
No RTL correction was needed for this milestone.

## Reproduction and measured captures

Follow the [normal-clone and detached-checkout command](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/08bde7496be07c83c3acd546ecef6bc7e6cc40b5/reports/dma-uvm-corrective-2026-11-10/REPRODUCE.md); it does not
depend on the feature branch name. The single `scripts/run_dma_uvm.py` command
checks the full environment SHA, clones the DUT at its unchanged lock and runs
the complete derived inventory. Use fresh output paths. Three new measured
figures show held inactive-lane transforms for tails 1 and 7 and busy rejected
write/readback behavior. Actual VCDs, original hashes, Git/raw byte hashes and
fresh autocrlf-false/true checkout checks accompany the figures. The historical
eight measured figures remain unchanged. No newline-only behavior change is claimed.

## Unexecuted work and limits

Functional coverage, constrained randomization and original advanced ALU/APB
environments remain **NOT RUN** for the established feature/licence limitations.
Procedural counters are not functional coverage. Archived multichannel DMA,
descriptors/scatter-gather, peripheral handshakes, multiple outstanding/reordered
transactions, full AXI compliance, coverage closure, synthesis, timing, FPGA and
hardware remain separate milestones. The prior eleven-project, APB and AXI4-Lite
releases and all M. Roohan Khan/Talib attribution and upstream notices remain.
Both focused PRs are open for review; no merged-main DMA UVM release is claimed.
