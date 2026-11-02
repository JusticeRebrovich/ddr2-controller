# DDR2 SDRAM Controller (SystemVerilog)

A synthesizable-style DDR2 SDRAM memory controller with a JEDEC power-up sequence, closed-page command
scheduling, periodic refresh, and a DQS/DQ PHY layer. It is verified in simulation against Micron's DDR2
bus-functional model with a scoreboard-based testbench, constrained-random tests, and a regression runner.

## Status

- Simulates cleanly in Vivado xsim 2020.2 at tCK = 2.5 ns (`sg25E` speed grade, x16 device)
- Regression: **9/9 PASS** (1 directed, 6 random seeds, 2 stress seeds), with **0 protocol errors or warnings**
  from the Micron model
- Not synthesized or run on hardware; this is a simulation project

## Architecture

```
tb_top.sv  (stimulus, scoreboard, monitor)
 ├── ddr2_top.sv  (DUT)
 │    ├── ddr2_ctrl.sv   command scheduler: closed-page FSM + refresh timer
 │    │    └── ddr2_init.sv   JEDEC power-up sequence (step table)
 │    └── ddr2_phy.sv    command launch, DQS/DQ write drive, read capture
 └── ddr2.v  Micron DDR2 model (not included, see below)
ddr2_pkg.sv   shared constants: timings in cycles, command encodings, mode registers
```

| Block | What it does |
| --- | --- |
| `ddr2_init.sv` | Walks the JEDEC initialization sequence from a step table (precharge, mode registers, DLL, refresh) |
| `ddr2_ctrl.sv` | Closed-page scheduler: ACTIVATE, READ/WRITE with auto-precharge, honoring tRCD, tRP, tRAS, tRC and tRFC; refresh timer with a margin below tREFI |
| `ddr2_phy.sv` | Drives command and address pins, generates DQS and DQ for writes, captures read data |
| `ddr2_pkg.sv` | Timing constants converted from the datasheet's picoseconds to clock cycles (rounded up) |

Mode registers: burst length 8, CL5, WR6, sequential burst, DLL enabled. Measured refresh interval is 7.64 µs,
under the 7.8 µs limit.

## Verification

Two independent pass criteria, because a behavioral memory model will happily store data even when timing is
violated:

1. **Functional:** read data must match what was written (a shadow-memory scoreboard)
2. **Protocol:** the Micron model's built-in timing checkers must report no errors

Testbench structure (the same split as UVM's sequence, scoreboard and monitor, without the library):

- **Stimulus:** `write` and `read` tasks, with `run_directed`, `run_random` and stress tests chosen by
  `+TEST=directed|random|stress`; seed set with `-sv_seed`
- **Scoreboard:** `shadow[]` holds what the DRAM should contain; `rd_q` holds the expected data for each outstanding read
- **Monitor:** checks every `rd_valid` against the scoreboard
- **Coverage counters:** refreshes issued, refresh while a request is waiting, banks hit
- **Regression runner** (`sim/regress.py`): builds once, runs every test and seed, classifies each run as
  PASS, FAIL, TIMEOUT or CRASH, and writes a Markdown report
- **Fault injection:** `FI_1` and `FI_2` defines plant controller bugs. The directed test still passes on the
  buggy build while the random and stress tests catch the faults, which is the case for constrained-random
  verification

## Running it

The Micron DDR2 model is not redistributed here because of its license. To run the simulation:

1. Download the Micron DDR2 SDRAM Verilog model (`ddr2.v`, `ddr2_parameters.vh`, `subtest.vh` and the
   `ddr2_module.v` / `ddr2_mcp.v` wrappers) from Micron's website and place the files in the repository root.
2. Edit `VIV` in `sim/run_xsim.bat` if Vivado is not at `C:\Xilinx\Vivado\2020.2`.
3. Run:

```bat
sim\run_xsim.bat          :: batch run, log in sim\sim.log
sim\run_xsim.bat gui      :: open waveforms
python sim\regress.py     :: full regression, report in sim\regress\<build>\report.md
python sim\regress.py --build buggy   :: regression with injected faults
```

## Known gaps

Back-to-back requests, a request arriving the same cycle refresh becomes pending, write-then-read to the same
address with no idle gap, reset in mid-operation, and SVA assertions on the controller's own rules.
[`LEARNING_LOG.md`](LEARNING_LOG.md) records each step, the tool problems hit, and the lessons learned.

## Author

Justice Rebrovich, University of North Dakota (B.S. Electrical Engineering).
