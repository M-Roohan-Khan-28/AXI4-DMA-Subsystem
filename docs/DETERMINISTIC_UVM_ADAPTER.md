# Separate deterministic DMA UVM/SVA adapter

The reusable environment is implemented in AMBA-Protocol-Verification, with
the real RTL in this repository pinned to **`a2d3d57edaa9eb441f3289bf5320f4df2f074144`**. This documentation PR
does not change RTL, the existing 40-case portable runner, source provenance,
licences, attribution or historical evidence.

## Tested environment and result

Environment: **`e93a6fdff85804dab7b5e636e43880e1ba7615ab`**; inventory:
`be4449ab5092a294c3be4b83b7bac0660e429530`. [Immutable evidence](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/3d17e3bed5396c828a76be13ff18229e39dea740/reports/dma-uvm-2026-11-09/SUMMARY.md) records a clean detached
GitHub run: **43/43 required substeps PASS**, aggregate and wrapper exit 0.
These comprise 30 standalone SVA controls (one legal plus 29 expected-negative),
five functional groups with 60 named scenarios, and eight fault qualifications.
Every fault child exited 1 for its intended cause. Independent command/burst/beat
and byte-memory accounting is included in the raw per-case JSON. The unchanged
portable suite passed 40 cases / 1,352,655 checks; 11 archived files passed the
existing provenance check. These quantities are not combined coverage.

The simulator was Questa Altera Starter FPGA Edition-64 2025.2, UVM runtime
QUESTA_UVM-1.2.3, deterministic seed `0x28A6BEEF`. The runner uses serial sessions,
direct `-onfinish exit`, bounded commands and explicit marker/error checking.
An earlier shutdown crash and separate network-blocked attempt remain failed
in the new report's development history. No simulator crash is treated as PASS.

## Adapter and supported contract

The [public-pin adapter and requirements guide](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/3d17e3bed5396c828a76be13ff18229e39dea740/docs/DETERMINISTIC_DMA_UVM.md) connect a UVM
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

Follow the [exact detached-checkout reproduction command](https://github.com/M-Roohan-Khan-28/AMBA-Protocol-Verification/blob/3d17e3bed5396c828a76be13ff18229e39dea740/reports/dma-uvm-2026-11-09/REPRODUCE.md). The
single top-level `scripts/run_dma_uvm.py` command lives in AMBA, checks the full
environment SHA and clones this DUT at the lock above. Fault children use new
detached local clones of that verified clean source. Choose fresh output paths.
Eight measured figures are tied to original raw VCD bytes and exact tick windows;
hashes were verified against Git blobs, public downloads and fresh checkouts.
No newline conversion or expected diagram is presented as a new measurement.

## Unexecuted work and limits

Functional coverage, constrained randomization and original advanced ALU/APB
environments remain **NOT RUN** for the established feature/licence limitations.
Procedural counters are not functional coverage. Archived multichannel DMA,
descriptors/scatter-gather, peripheral handshakes, multiple outstanding/reordered
transactions, full AXI compliance, coverage closure, synthesis, timing, FPGA and
hardware remain separate milestones. The prior eleven-project, APB and AXI4-Lite
releases and all M. Roohan Khan/Talib attribution and upstream notices remain.
Both focused PRs are open for review; no merged-main DMA UVM release is claimed.
