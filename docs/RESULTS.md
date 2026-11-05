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

The published clean-clone result will be recorded separately with its tested
revision. No advanced four-channel or descriptor environment, coverage,
synthesis, timing, FPGA, or hardware result is claimed.
