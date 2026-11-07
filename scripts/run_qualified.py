#!/usr/bin/env python3
"""Run the named DMA inventory or one selected case in fresh isolated output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def tool(name):
    prefix = os.environ.get("MODELSIM_BIN")
    choices = ([str(Path(prefix) / (name + ".exe")), str(Path(prefix) / name)]
               if prefix else []) + [name, name + ".exe"]
    for choice in choices:
        found = shutil.which(choice)
        if found:
            return found
    raise RuntimeError("Missing simulator tool: " + name)


def invoke(argv, cwd, logpath, timeout=120):
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True,
                                timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        logpath.write_bytes((exc.stdout or b"") + (exc.stderr or b""))
        raise RuntimeError("Command timed out after %d seconds" % timeout) from exc
    raw = result.stdout + result.stderr
    logpath.write_bytes(raw)
    return result.returncode, raw.decode("utf-8", errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output-dir", type=Path, required=True)
    ap.add_argument("--case", help="run one named case; full inventory is default")
    ap.add_argument("--rtl", type=Path, help="disposable source override")
    ap.add_argument("--capture-wave", action="store_true")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    if out.exists():
        raise RuntimeError("Output directory exists: " + str(out))
    out.mkdir(parents=True)
    rtl = (args.rtl or root / "rtl/axi4_dma_subsystem.sv").resolve()
    tb = root / "tb/tb_dma_portable.sv"
    inventory_file = root / "tests/required_cases.json"
    inventory = json.loads(inventory_file.read_text(encoding="utf-8"))
    required = inventory["required_cases"]
    report = {
        "repository": "AXI4-DMA-Subsystem",
        "source_revision": subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
        "source_dirty": bool(subprocess.check_output(
            ["git", "-C", str(root), "status", "--porcelain"])),
        "sources": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                    for p in (rtl, tb, inventory_file)],
        "seed": "0x28A6BEEF", "case_selection": args.case or "ALL",
        "timeout_seconds_per_command": 120,
        "simulations": [], "overall": "FAIL"
    }
    started = time.monotonic()
    try:
        if len(required) != len(set(required)) or not required:
            raise RuntimeError("Duplicate or empty required inventory")
        if args.case and args.case not in required:
            raise RuntimeError("Unknown selected case: " + args.case)
        if args.capture_wave and not args.case:
            raise RuntimeError("Select one case for bounded wave capture")
        vlib, vlog, vsim = (tool(n) for n in ("vlib", "vlog", "vsim"))
        report["simulator_version"] = invoke([vsim, "-version"], out,
                                              out / "version.log")[1].strip()
        if invoke([vlib, "work"], out, out / "library.log")[0]:
            raise RuntimeError("vlib failed")
        code, compile_log = invoke([vlog, "-sv", str(rtl), str(tb)], out,
                                   out / "compile.log")
        if code or "Errors: 0, Warnings: 0" not in compile_log:
            raise RuntimeError("vlog failed or reported diagnostics")
        do = "run -all; quit -code 0"
        if args.capture_wave:
            signals = "aclk aresetn m_axi_awvalid m_axi_awready m_axi_wvalid m_axi_wready m_axi_wlast m_axi_bvalid m_axi_bready".split()
            do = ("vcd file dma-order.vcd; " + "; ".join(
                  "vcd add /tb_dma_portable/" + s for s in signals) + "; " + do)
        command = [vsim, "-c", "-onfinish", "exit", "tb_dma_portable"]
        if args.case:
            command.append("+CASE=" + args.case)
        command += ["-do", do]
        code, log = invoke(command, out, out / "simulation.log")
        entry = {"top": "tb_dma_portable", "command": command,
                 "simulator_exit_code": code, "status": "FAIL"}
        report["simulations"].append(entry)
        expected = [args.case] if args.case else required
        starts = re.findall(r"DMA_CASE_START ([A-Za-z0-9_]+) time=", log)
        passes = re.findall(r"DMA_CASE_PASS ([A-Za-z0-9_]+)(?: length=| time=)", log)
        summary = re.findall(r"DMA_REGRESSION_PASS cases=(\d+) checks=(\d+) seed=0x([0-9A-Fa-f]+)", log)
        if (code or re.search(r"\*\*\s+(?:Error|Fatal):", log) or
                "# Errors: 0, Warnings: 0" not in log or "$finish" not in log or
                starts != expected or passes != expected or len(summary) != 1 or
                int(summary[0][0]) != len(expected) or int(summary[0][1]) <= 0 or
                summary[0][2].upper() != "28A6BEEF"):
            raise RuntimeError("DMA simulation failed, inventory mismatch or marker missing")
        if not args.case and int(summary[0][1]) != inventory["expected_checks"]:
            raise RuntimeError("DMA check total differs from qualified inventory")
        entry.update(status="PASS", cases=len(expected), checks=int(summary[0][1]))
        report["cases"] = expected
        report["checks"] = int(summary[0][1])
        if args.capture_wave:
            vcd = out / "dma-order.vcd"
            if not vcd.is_file() or not vcd.stat().st_size:
                raise RuntimeError("Requested VCD missing")
            report["waveform"] = {"path": str(vcd),
                                  "sha256": hashlib.sha256(vcd.read_bytes()).hexdigest()}
            names = ["tb_dma_portable." + s for s in signals]
            render = [sys.executable, str(root / "tools/vcd_to_svg.py"), "--vcd", str(vcd),
                      "--signals", *names, "--output", str(out / "dma-order.svg"),
                      "--origin", "simulator", "--title", "Measured DMA AW/W ordering"]
            if invoke(render, out, out / "render.log")[0]:
                raise RuntimeError("VCD render failed")
        report["overall"] = "PASS"
        print("DMA_REGRESSION_PASS cases=%d checks=%d seed=0x28A6BEEF" %
              (len(expected), report["checks"]))
    except Exception as exc:
        report["error"] = str(exc)
        print("FAIL: " + str(exc), file=sys.stderr)
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n",
                                          encoding="utf-8")
    return 0 if report["overall"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
