#!/usr/bin/env python3
"""regress.py -- build once, run every test x seed in xsim, then triage the results.

Usage (run from anywhere):
  python regress.py                          clean design, default test list
  python regress.py --build buggy            same regression with injected faults
  python regress.py --seeds 20               more random seeds per test
  python regress.py --build buggy --rerun random 7         rerun one failing case
  python regress.py --build buggy --rerun random 7 --gui   ...in the waveform viewer

Pass/fail rules for one run:
  PASS     log ends in "TEST PASSED" and contains no ERROR lines (ours or the model's)
  FAIL     any ERROR line, from the scoreboard or from Micron's timing checkers
  TIMEOUT  the testbench watchdog fired
  CRASH    no final verdict line at all (compile problem, fatal, tool crash)

Triage: each failing run is labelled by its FIRST error, with times and numbers
stripped out (its "signature"). Runs with the same signature are one bucket,
which usually means one root cause.
"""

import argparse
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
VIVADO_BIN = Path(r"C:\Xilinx\Vivado\2020.2\bin")

SV_SOURCES = ["ddr2_pkg.sv", "ddr2_init.sv", "ddr2_ctrl.sv",
              "ddr2_phy.sv", "ddr2_top.sv", "tb_top.sv"]
V_SOURCES = ["ddr2.v"]
BASE_DEFINES = ["sg25E", "x16"]

# Build configurations: name -> extra `defines.
# "buggy" turns on training fault injection in the RTL. Don't read those
# ifdefs until you've triaged the failures yourself.
BUILDS = {
    "clean": [],
    "buggy": ["FI_1", "FI_2"],
}

# Test list: (test name, number of seeds, extra plusargs)
# Seeds for each test are 1..N, so any failure is reproducible by number.
def test_list(n_seeds):
    return [
        ("directed", 1,       {}),
        ("random",   n_seeds, {"N_OPS": 200}),
        ("stress",   max(2, n_seeds // 3), {"N_OPS": 300}),
    ]


# ---------------------------------------------------------------- tool calls
def tool(name, args, log_name):
    """Run a Vivado .bat tool from the sim dir. Returns True on success."""
    # Vivado's .bat wrappers split arguments on '=' and spaces unless each one is
    # quoted, so build the command line by hand with every argument in quotes.
    cmd = f'cmd /c {VIVADO_BIN / (name + ".bat")} ' + " ".join(f'"{a}"' for a in args)
    with open(SIM_DIR / log_name, "w") as log:
        rc = subprocess.run(cmd, cwd=SIM_DIR, stdout=log, stderr=subprocess.STDOUT).returncode
    return rc == 0


def build(build_name):
    snap = f"snap_{build_name}"
    defs = []
    for d in BASE_DEFINES + BUILDS[build_name]:
        defs += ["-d", d]
    print(f"Building '{build_name}' ...", flush=True)
    ok = (tool("xvlog", ["-sv"] + defs + ["-i", ".."] + [f"../{s}" for s in SV_SOURCES],
               "build_xvlog_sv.log")
          and tool("xvlog", defs + ["-i", ".."] + [f"../{s}" for s in V_SOURCES],
                   "build_xvlog_v.log")
          and (tool("xelab", ["-debug", "typical", "-timescale", "1ps/1ps",
                              "tb_top", "-s", snap], "build_xelab.log")
               # xelab can exit non-zero just because OneDrive/antivirus locked a
               # temp folder it tried to delete; the snapshot is still fine.
               or f"Built simulation snapshot {snap}"
                  in (SIM_DIR / "build_xelab.log").read_text(errors="replace")))
    if not ok:
        print("BUILD FAILED. See sim/build_*.log")
        sys.exit(1)
    return snap


def plusargs(test, seed, extra):
    args = ["-sv_seed", str(seed),
            "-testplusarg", f"TEST={test}", "-testplusarg", f"SEED={seed}"]
    for k, v in extra.items():
        args += ["-testplusarg", f"{k}={v}"]
    return args


# ---------------------------------------------------------------- log parsing
ERROR_RE = re.compile(r"ERROR")
NUM_RE = re.compile(r"\b(0x)?[0-9a-fA-F]*[0-9][0-9a-fA-F]*\b")


def signature(line):
    """Turn one error line into a stable bucket key."""
    src = "model" if "u_mem" in line else "tb"
    text = line[line.index("ERROR"):]
    text = re.sub(r"=\s*[0-9a-fA-FxXzZ]+", "=#", text)   # field=value  -> field=#
    text = NUM_RE.sub("#", text)                          # any other number
    text = re.sub(r"\s+", " ", text).strip()
    return f"[{src}] {text}"


def parse(log_path):
    r = {"status": "CRASH", "errors": 0, "warnings": 0,
         "first_error": None, "first_time": None, "sigs": set()}
    if not log_path.exists():
        return r
    for line in log_path.read_text(errors="replace").splitlines():
        if ERROR_RE.search(line):
            r["errors"] += 1
            sig = signature(line)
            r["sigs"].add(sig)
            if r["first_error"] is None:
                r["first_error"] = sig
                m = re.search(r"at time\s+([\d.]+)\s*ps|^\[(\d+)", line)
                if m:
                    r["first_time"] = float(m.group(1) or m.group(2))
        elif "WARNING" in line and "u_mem" in line:
            r["warnings"] += 1
        if "TIMEOUT" in line:
            r["status"] = "TIMEOUT"
        elif "TEST PASSED" in line and r["status"] != "TIMEOUT":
            r["status"] = "PASS"
        elif "TEST FAILED" in line and r["status"] != "TIMEOUT":
            r["status"] = "FAIL"
    if r["status"] == "PASS" and r["errors"]:
        r["status"] = "FAIL"   # model errors fail the run even if the data matched
    return r


# ---------------------------------------------------------------- main flows
def run_regression(build_name, n_seeds):
    snap = build(build_name)
    log_dir = SIM_DIR / "regress" / build_name
    log_dir.mkdir(parents=True, exist_ok=True)

    results = []
    jobs = [(t, s, extra) for t, n, extra in test_list(n_seeds) for s in range(1, n + 1)]
    print(f"Running {len(jobs)} simulations\n")
    t_start = time.time()
    for i, (test, seed, extra) in enumerate(jobs, 1):
        log = log_dir / f"{test}_s{seed}.log"
        t0 = time.time()
        tool("xsim", [snap, "-runall", "-log", str(log.relative_to(SIM_DIR))] + plusargs(test, seed, extra),
             "regress_xsim_console.log")
        r = parse(log)
        r.update(test=test, seed=seed, log=log, secs=time.time() - t0)
        results.append(r)
        print(f"  [{i:2}/{len(jobs)}] {test:9} seed {seed:<3} {r['status']:7} "
              f"{r['errors']:3} err  {r['secs']:5.1f}s")

    report(build_name, results, time.time() - t_start)


def report(build_name, results, total_secs):
    n_pass = sum(r["status"] == "PASS" for r in results)
    lines = [f"# Regression report: build '{build_name}'", "",
             f"**{n_pass}/{len(results)} passed** in {total_secs:.0f} s", "",
             "| test | seed | status | errors | model warnings | first error |",
             "|---|---|---|---|---|---|"]
    for r in results:
        lines.append(f"| {r['test']} | {r['seed']} | {r['status']} | {r['errors']} | "
                     f"{r['warnings']} | {r['first_error'] or ''} |")

    # Triage: bucket failing runs by their first error signature
    buckets = defaultdict(list)
    for r in results:
        if r["status"] != "PASS":
            buckets[r["first_error"] or r["status"]].append(r)

    lines += ["", "## Triage buckets (grouped by first error)", ""]
    if not buckets:
        lines.append("No failures.")
    for i, (sig, runs) in enumerate(sorted(buckets.items(), key=lambda kv: -len(kv[1])), 1):
        # Best repro = the run that fails earliest: shortest sim, least noise
        best = min(runs, key=lambda r: r["first_time"] or float("inf"))
        where = ", ".join(f"{r['test']} s{r['seed']}" for r in runs)
        lines += [f"### Bucket {i}: `{sig}`",
                  f"- {len(runs)} run(s): {where}",
                  f"- Earliest failure: {best['test']} seed {best['seed']}"
                  + (f" at {best['first_time']/1e6:.3f} us" if best["first_time"] else ""),
                  f"- Rerun: `python regress.py --build {build_name} --rerun {best['test']} {best['seed']}`",
                  ""]
        also = set().union(*(r["sigs"] for r in runs)) - {sig}
        if also:
            lines.append("- Other errors seen in these runs (often knock-on effects):")
            lines += [f"  - `{s}`" for s in sorted(also)]
            lines.append("")

    text = "\n".join(lines)
    out = SIM_DIR / "regress" / build_name / "report.md"
    out.write_text(text)
    print("\n" + text)
    print(f"\nReport saved to {out}")


def rerun(build_name, test, seed, gui, n_ops):
    snap = build(build_name)
    extra = {"N_OPS": n_ops} if n_ops else dict(next(
        (e for t, _, e in test_list(1) if t == test), {}))
    args = [snap] + plusargs(test, seed, extra)
    if gui:
        print("Opening waveform viewer ...")
        tool("xsim", args + ["-gui", "-tclbatch", "wave.tcl"], "rerun_console.log")
        return
    log = SIM_DIR / f"rerun_{test}_s{seed}.log"
    tool("xsim", args + ["-runall", "-log", str(log.relative_to(SIM_DIR))], "rerun_console.log")
    r = parse(log)
    print(f"\n{test} seed {seed}: {r['status']}, {r['errors']} error(s). Full log: {log}\n")
    for line in log.read_text(errors="replace").splitlines():
        if "ERROR" in line or "WARNING" in line or "TEST " in line or "coverage" in line \
                or line.startswith(" ") and ("=" in line):
            print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", choices=BUILDS, default="clean")
    ap.add_argument("--seeds", type=int, default=6, help="seeds for the random test")
    ap.add_argument("--rerun", nargs=2, metavar=("TEST", "SEED"))
    ap.add_argument("--gui", action="store_true", help="with --rerun: open waveforms")
    ap.add_argument("--n-ops", type=int, help="with --rerun: override N_OPS")
    a = ap.parse_args()
    if a.rerun:
        rerun(a.build, a.rerun[0], int(a.rerun[1]), a.gui, a.n_ops)
    else:
        run_regression(a.build, a.seeds)


if __name__ == "__main__":
    main()
