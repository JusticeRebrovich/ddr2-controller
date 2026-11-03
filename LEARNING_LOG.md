# DDR2 Controller: Learning Log

A running record of what we did, why, and what it teaches, written for interview prep.

## Project map

```
tb_top.sv  (testbench: stimulus + checker)
 ├── ddr2_top.sv  (DUT)
 │    ├── ddr2_ctrl.sv   command scheduler (closed-page FSM + refresh timer)
 │    │    └── ddr2_init.sv   JEDEC power-up sequence (step table)
 │    └── ddr2_phy.sv    drives pins: command launch, DQS/DQ write, read capture
 └── ddr2.v  (Micron DDR2 memory model: the "golden" DRAM with built-in timing checks)
ddr2_pkg.sv          shared constants (timings in cycles, command encodings, mode regs)
ddr2_parameters.vh   Micron's timing table (ps), selected by `define sg25E / x16
```

## Steps

### Step 1: Connected the project to Claude Code (2026-09-30)
- Added this folder to the session so Claude can read, edit and run tools here.
- **Claude Code skill:** Claude works on files it can see. Start sessions *in the project folder*.

### Step 2: Checked timing constants against the spec
- Compared `ddr2_pkg.sv` (cycles) with `ddr2_parameters.vh` sg25E (ps) at tCK = 2.5 ns.
- tRCD 12.5 ns → 5, tRP 12.5 → 5, tRPA 15 → 6, tRC 55 → 22, tRFC 197.5 → 79: all correct (ceil).
- tRAS: spec 40 ns → 16 cycles; we use 18. Conservative, so legal but slightly slower.
- **DV lesson:** constants are a top bug source. Always trace them back to the datasheet.

### Step 3: Built an xsim flow (`sim/run_xsim.bat`)
- `tb.do` is Micron's ModelSim script for *their* testbench, not ours.
- xsim's three steps: **xvlog** (compile) → **xelab** (elaborate/link) → **xsim** (run).
- Defines `sg25E` and `x16` select the speed grade and width inside the Micron model.
- Run: `sim\run_xsim.bat` (batch) or `sim\run_xsim.bat gui` (waveforms).

### Step 4: First simulation, PASSED
- 9 PASS / 0 FAIL, and **0 ERROR/WARNING lines from the Micron model** in `sim/sim.log`.
- Model confirmed the mode registers: BL8, CL5, WR6, sequential burst, DLL enabled.
- Refresh interval measured at 7.64 µs = (T_REFI − REF_MARGIN) × 2.5 ns, under the 7.8 µs limit.
- **DV lesson: two separate pass criteria.**
  1. *Functional*: did the data read back match? (our scoreboard: `expected[]`)
  2. *Protocol*: did we obey every timing rule? (the Micron model's built-in checkers)
  A test can pass #1 and still fail #2, because behavioral memory models store data even
  when timing is violated. Always grep the log for the model's ERROR lines.

### Step 5: Testbench upgraded to scoreboard architecture (2026-10-05)
- **Stimulus** (`write`/`read` tasks, `run_directed`/`run_random`), **scoreboard**
  (`shadow[]` = what DRAM should hold, `rd_q` = expected data per outstanding read),
  **monitor** (checks every `rd_valid` against `rd_q`). Same split as UVM's
  sequence / scoreboard / monitor, without the library.
- Reads are now non-blocking: the test issues them and the monitor checks them later.
- Tests picked by plusarg: `+TEST=directed|random|stress`. Seed via `xsim -sv_seed N`.
- Every check prints `ERROR [ID] ...` (a consistent format lets scripts triage).
- Simple coverage counters: refreshes, refresh-while-request-waiting, banks hit.

### Step 6: Regression runner (`sim/regress.py`)
- Builds once, runs every test x seed, parses logs, writes `sim/regress/<build>/report.md`.
- Status rules: PASS / FAIL (any ERROR, ours *or the model's*) / TIMEOUT / CRASH.
- **Tool lessons hit along the way (real-world debugging):**
  - xsim 2020.2 doesn't support `$urandom(seed)`, so the seed goes in via `-sv_seed`.
  - xelab returned failure only because OneDrive locked a temp folder; the build was fine.
    Lesson: check the log, not just the exit code.
  - Vivado's `.bat` wrappers split on `=` and spaces, so every argument must be quoted.
  - **All runs failing identically in <1 s = infrastructure problem, not a design bug.**

### Step 7: Clean baseline = 9/9 PASS
- Always establish a clean baseline before hunting bugs.
- Coverage showed: the directed test **never** has a request waiting when refresh fires
  (`refresh_while_request_waiting=0`); random/stress hit it. Directed tests miss corners.

### Step 8: Buggy build regression = 1/9 PASS (triage exercise, in progress)
- Injected faults behind `FI_1` / `FI_2` defines (`python regress.py --build buggy`).
- **The directed test still PASSES on the buggy design.** That's the whole argument for
  constrained-random verification in one line.
- Triage questions to answer yourself:
  1. How many distinct bugs are there? Is "bucket by first error" telling the full truth?
  2. Which bucket do you debug first, and with which seed? Why?
  3. Why does the directed test pass?

### Step 9: SVA timing checker (`ddr2_timing_checker.sv`, 2026-11-02)
- Concurrent assertions on the command pins: tRCD, tRP, tRPA, tRAS, tRC, tRRD, tFAW, tRFC, tRTP, tWR, tREFI,
  plus bank-state rules (ACT to an open bank, READ/WRITE to a closed bank, REFRESH with a bank open).
- **Limits come from the datasheet in ps, not from `ddr2_pkg.sv`.** The controller uses tRAS = 18 cycles
  where the datasheet says 40 ns = 16. A checker that reuses the controller's constants would agree with the
  controller's mistakes.
- xsim 2020.2 handles `|=>`, `[*N]`, `disable iff`, `generate` loops and `$countones`, enough for all of the above.
- **A checker that never fires proves nothing.** `tb_checker_selftest.sv` drives illegal command streams into it:
  at the limit must stay quiet, one cycle early must fire that rule and only that rule (25 cases). Writing the
  one-cycle-early cases also exposed my own off-by-one in tRFC (the first command is allowed at +79, not +80).
- tRRD and tFAW can never fail with this closed-page controller. Only the self-test shows they work.
- New timing fault injections `FI_3` (tRAS), `FI_4` (tRCD), `FI_5` (tRP) are caught by both the SVA checker and
  Micron's model.

### Step 10: SECDED ECC (`ddr2_ecc.sv`)
- Extended Hamming (128,120): 7 Hamming check bits at positions 1,2,4..64, an overall parity bit at position 0.
  A BL8 x16 burst is exactly 128 bits, so 120 data + 8 check bits fits with no extra DRAM lane.
- The syndrome names the flipped bit; the overall parity tells one error from two. Syndrome 0 with bad parity
  means the parity bit itself flipped, so the data is untouched.
- **Exhaustive beats sampled.** The codec test flips every one of 128 bits and every one of 8128 pairs; a random
  test would take far longer to give the same confidence.
- **DV lesson:** a SECDED decoder that ignores the overall parity still corrects single errors perfectly, and
  silently miscorrects double errors. Only a test that injects double errors and checks `dbe` can see it
  (`FI_ECC_1`).
- `inj_mask` XORs into the codeword at write time, so the same test runs through the real controller and
  Micron's model, with the counters cross-checked against the scoreboard.

### Step 11: Regression covers fault builds (`python sim/regress.py --all`)
- Real designs must pass; every fault build must fail at least one run. This turns "the testbench passes" into
  "the testbench can fail".
- **Tool lessons:** `cmd /c` strips the outer quotes of a long quoted command line (wrap the whole line in one more
  pair); Vivado's `.bat` wrappers split arguments on `=` (quote each argument).

### What this testbench does NOT cover yet (coverage gaps)
- Back-to-back requests (req_valid held high continuously)
- A request arriving on the same cycle refresh becomes pending
- Write→read to the *same* address with no idle gap
- Reset in the middle of operation
- ECC is a separate top, so the main controller testbench does not exercise it, and corrected data is not written back
