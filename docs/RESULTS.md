# Validation results

The first development run on 6 November 2026 used ModelSim Intel FPGA
Starter Edition `vsim 2020.1 Simulator 2020.02 Feb 28 2020`.
`scripts/run_regression.ps1` compiled the new RTL and testbench with
0 errors/0 warnings, then completed 25 scenarios and printed 824,446
recorded comparisons with seed `0x28A6BEEF`; wrapper exit was 0.
The source tree was **uncommitted** at that run, based on documentation
commit `922c5640a519152aba767e43be22e5155e9edd84`.
It is development evidence, not yet the publication gate.

The committed-source and published clean-clone results will be recorded
separately, with their exact tested source revision. No advanced four-channel
or descriptor environment, coverage, synthesis, timing, FPGA, or hardware
result is claimed.
