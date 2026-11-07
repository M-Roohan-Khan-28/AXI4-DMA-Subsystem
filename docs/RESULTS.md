# Validation results

The first development run on 6 November 2026 used ModelSim Intel FPGA
Starter Edition `vsim 2020.1 Simulator 2020.02 Feb 28 2020`.
`scripts/run_regression.ps1` compiled the new RTL and testbench with
0 errors/0 warnings, then completed 25 scenarios and printed 824,446
recorded comparisons with seed `0x28A6BEEF`; wrapper exit was 0.
The source tree was **uncommitted** at that run, based on documentation
commit `922c5640a519152aba767e43be22e5155e9edd84`.
It is development evidence, not yet the publication gate.

The first committed-source run used revision
`f08b294e079b6edd1cb2f5d61b2305d4ba0ca8af` with a clean worktree.
The exact command was:

```powershell
$env:PATH='C:\intelFPGA\20.1\modelsim_ase\win32aloem;'+$env:PATH
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_regression.ps1 -OutputDir C:\R_MIGRATION_BACKUP\Roohan_GitHub_Launch_Kit\Roohan_GitHub_Launch_Kit\build\test-runs\dma-committed-2026-11-06
```

Compilation reported 0 errors and 0 warnings. ModelSim Intel FPGA Starter
Edition `vsim 2020.1 Simulator 2020.02 Feb 28 2020` exited 0. The wrapper
exited 0 after **25 cases and 824,446 comparisons**, seed `0x28A6BEEF`.
The raw compile/simulation logs and JSON result are in
`reports/committed-2026-11-06/`. Provenance verification returned
`PROVENANCE_PASS files=11` against upstream commit
`85868386f1d4c105b8baa666c5a6c273756fa8e5`.

A disposable clone changed the default AXI write strobes to zero. Its
simulation reported `Fatal: eight accepted bus mismatch` with 1 simulator
error; the regression wrapper exited **1**. This confirms the actual
failure path without changing the committed RTL.

The published source was cloned from
`https://github.com/M-Roohan-Khan-28/AXI4-DMA-Subsystem.git` at
`670cb280d5ec4b26cf436f10fe5a5be22abb5c90` and run from that
fresh checkout:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_regression.ps1 -OutputDir C:\R_MIGRATION_BACKUP\Roohan_GitHub_Launch_Kit\Roohan_GitHub_Launch_Kit\build\test-runs\dma-published-clone-2026-11-06
python scripts/check_provenance.py
```

ModelSim Intel FPGA Starter Edition 2020.1 compiled with 0 errors and
0 warnings. The simulator and wrapper each exited 0; the bench reported
**25 cases, 824,446 comparisons, seed `0x28A6BEEF`**. The provenance
checker exited 0 for all 11 archived files. Raw logs and JSON result are
under `reports/published-clone-2026-11-06/`.

The portfolio aggregate then ran nine mandatory suites, including this DMA
suite, from isolated GitHub clones; all nine passed and the aggregate exit
was **0**. Its DMA entry identifies the same published source revision and
25 cases. This is a cross-project regression result, not a coverage metric.

No advanced four-channel or descriptor environment, coverage, synthesis,
timing, FPGA, or hardware result is claimed.

## Corrective write-channel and oracle run — 7 November 2026

Committed source `7e6c25d5a72e2f033299a9d9c205e799fd64b721` ran
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_regression.ps1 -OutputDir build/corrective-dma-committed-2026-11-07` with ModelSim Intel FPGA Starter Edition `vsim 2020.1 Simulator 2020.02 Feb 28 2020`.
Compilation reported 0 errors and 0 warnings; simulator and wrapper exits
were 0. The actual result is **27 cases, 925,460 checks**, seed
`0x28A6BEEF`, with `dirty_source=false`. The two added cases hold AWREADY
until WVALID and accept W before AW, respectively. Accepted AR/AW addresses,
lengths and R/W progression are checked against a separate programmed-request
model; memory bytes come from a fixed-seed pseudorandom stream. Raw compile,
simulation and result JSON are in `reports/corrective-2026-11-07/committed/`.
The archived 11-file upstream provenance checker exited 0.

The original RTL `7035f579ce8d19d5f06e51b4400789abdf5c22a7` with the
new bench in a disposable worktree timed out on `awready_waits_wvalid` at
503,810 ns; the wrapper exited **1**. A separate disposable source-address
alias (`cur_src <= src_reg & 32'hFFFF_FF00`) with the corrected RTL triggered
`AR oracle mismatch got=00000100/0 expected=00000180/0`; the wrapper exited
**1**. Raw fault logs and the exact mutation summaries are in the sibling
`old-rtl-new-bench/` and `source-alias-fault/` folders. These failures are
intentional and are not counted as passing regressions. Full AXI4 protocol
compliance and measured coverage remain outside this bounded milestone.

## Full-burst channel-ordering qualification — 7 November 2026

Tested source/runner/inventory commit:
`a2148a1e817b0981714962264e3af4a7fb838ea6`, clean worktree.
ModelSim Intel FPGA Starter Edition `vsim 2020.1 Simulator 2020.02
Feb 28 2020`, seed `0x28A6BEEF`. The fresh full run passed the
[exact 40-case inventory](../tests/required_cases.json) with **1,352,655**
check observations and wrapper exit **0**. Its source SHA-256 values, actual
command, simulator banner, raw compile/simulation logs, terminal markers
and JSON are in [`reports/technical-completion-2026-11-07/`](../reports/technical-completion-2026-11-07/).

The new responder buffers up to 16 accepted W beats before AW. Selected
1-, 2- and 16-beat cases passed with all W before AW; separate cases passed
same-cycle AW/first-W acceptance. The earlier 27 cases remain, with all
final-byte tails 1–7 and a coincident source/destination 4 KiB split added.
The independent request oracle compares every accepted address, length,
beat, strobe and byte against the programmed request; full memory and guard
bytes are compared after each case. These are check totals, not measured
functional or code coverage.

Four selected passing case runs captured real VCDs and
[VCD-derived SVGs](../reports/technical-completion-2026-11-07/) for
`all_w_before_aw_16`, `same_cycle_16`, `awready_waits_wvalid` and
`both_boundaries`. Each adjacent metadata JSON records source VCD SHA-256,
top, tick unit, signal map and actual interval. The renderer does not itself
judge functional PASS.

Two disposable RTL tracker faults had targeted nonzero wrapper results:
forcing `aw_done` low caused `burst128` to time out; forcing `w_done` low
caused `all_w_before_aw_16` to time out. Each had the named simulator fatal
`DMA completion timeout`; their fault directories contain mutant sources,
hashes, compile/simulation logs, JSON and wrapper-exit summaries. A separate
AW-tracker mutant in an all-W-before-AW case passed because the AW and final W
dependencies were both met on the AW edge; the AW-first `burst128` target
was therefore used to qualify that tracker. No mutant entered the branch.
The prior old-RTL and source-alias controls remain in their historical paths.

Reproduce full inventory from this commit with fresh output:

```powershell
$env:MODELSIM_BIN = 'C:\intelFPGA\20.1\modelsim_ase\win32aloem'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_regression.ps1 -OutputDir C:\short\dma-full-unique
if ($LASTEXITCODE -ne 0) { throw 'DMA regression failed or blocked' }
```

Response-error position, wrong-ID and malformed-RLAST matrices, additional
CSR/reset phases, UVM, SVA, coverage closure and full AXI4 compliance remain
open. No synthesis, timing, FPGA or hardware evidence is claimed.
