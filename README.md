# DDR2 SDRAM Controller with SVA Timing Checks and SECDED ECC (SystemVerilog)

A DDR2 SDRAM memory controller with a JEDEC power-up sequence, closed-page command scheduling, periodic refresh,
and a DQS/DQ PHY layer, plus two verification and reliability additions: a bus-level **SystemVerilog assertion
(SVA) timing checker** and a **SECDED ECC** datapath with error injection. Everything is verified in simulation
against Micron's DDR2 bus-functional model.

## Status

- Simulates in Vivado xsim 2020.2 at tCK = 2.5 ns (`sg25E` speed grade, x16 device)
- Controller regression: 9/9 PASS (directed, random and stress), 0 Micron-model errors, 0 assertion failures
- Timing checker self-test: 25/25 cases (each rule fires one cycle early, stays quiet at the limit)
- ECC: exhaustive codec test plus DRAM-level error injection, all passing
- Fault-injection builds: every injected bug is caught (see [Regression](#regression))
- Simulation only, not synthesized or run on hardware

## Architecture

```
tb_top.sv  (stimulus, scoreboard, monitor)
 ├── ddr2_top.sv  (DUT)
 │    ├── ddr2_ctrl.sv   command scheduler: closed-page FSM + refresh timer
 │    │    └── ddr2_init.sv   JEDEC power-up sequence (step table)
 │    └── ddr2_phy.sv    command launch, DQS/DQ write drive, read capture
 ├── ddr2_timing_checker.sv   SVA assertions on the command pins
 └── ddr2.v  Micron DDR2 model (not included, see below)

ddr2_ecc.sv    SECDED (128,120) functions and ddr2_ecc_top, which wraps ddr2_top
tb_ecc.sv      ECC testbench with error injection
ddr2_pkg.sv    shared constants: timings in cycles, command encodings, mode registers
```

| Block | What it does |
| --- | --- |
| `ddr2_init.sv` | Walks the JEDEC initialization sequence from a step table (precharge, mode registers, DLL, refresh) |
| `ddr2_ctrl.sv` | Closed-page scheduler: ACTIVATE, READ or WRITE, explicit PRECHARGE, honoring tRCD, tRP, tRAS, tRC, tRFC and write/read recovery; refresh timer with a margin below tREFI |
| `ddr2_phy.sv` | Drives command and address pins, generates DQS and DQ for writes, captures read data |
| `ddr2_timing_checker.sv` | Concurrent SVA assertions on the pins between controller and memory |
| `ddr2_ecc.sv` | Extended Hamming SECDED code and the ECC wrapper |

Mode registers: burst length 8, CL5, WR6, sequential burst, DLL enabled. Measured refresh interval is 7.64 µs,
under the 7.8 µs limit.

## SVA timing checker

[`ddr2_timing_checker.sv`](ddr2_timing_checker.sv) watches the command pins, so it checks what the DRAM actually
sees. Its limits come from the MT47H128M16 -25E datasheet in picoseconds and are converted to cycles inside the
checker, independently of the cycle constants in `ddr2_pkg.sv`. A controller constant that is too small fails an
assertion instead of agreeing with itself.

| Rule | Checked |
| --- | --- |
| tRCD | ACT to READ/WRITE, same bank (5 cycles) |
| tRP, tRPA | PRECHARGE to ACT or REFRESH, same bank (5) and after PRECHARGE ALL (6) |
| tRAS | ACT to PRECHARGE, same bank (16) |
| tRC | ACT to ACT, same bank (22) |
| tRRD | ACT to ACT, any bank (4) |
| tFAW | at most 4 ACTs in any 18-cycle window |
| tRFC | no command for 79 cycles after REFRESH |
| tRTP, tWR | READ to PRECHARGE (5), WRITE to PRECHARGE (14) |
| tREFI | a REFRESH at least every 3120 cycles |
| bank state | ACT only to a closed bank, READ/WRITE only to an open bank, REFRESH only with all banks closed |

Because a checker that never fires proves nothing, [`tb_checker_selftest.sv`](tb_checker_selftest.sv) drives
hand-built command streams straight into it: each rule is tested with the command exactly at the limit (must stay
quiet) and one cycle early (must fire that rule and no other). 25 cases pass. Note that tRRD and tFAW cannot fail
with this closed-page controller, which never has two banks active; the self-test is what proves those two
assertions work, and they matter once the controller gains bank interleaving.

## SECDED ECC

[`ddr2_ecc.sv`](ddr2_ecc.sv) implements an extended Hamming (128,120) code: single-error correct, double-error
detect. One BL8 burst on the x16 device is exactly 128 bits, so a burst carries 120 data bits plus 8 check bits and
no extra DRAM lane is needed (the cost is 120 usable bits per burst instead of 128).

- `ddr2_ecc_top` wraps the controller: it encodes on writes and decodes on reads, and returns `rd_sbe` (single
  error corrected) and `rd_dbe` (double error detected) with each read, plus running error counters.
- `inj_mask` is XORed into the codeword as it is written, which models bits that went bad in storage.
- [`tb_ecc_codec.sv`](tb_ecc_codec.sv) checks the code on its own, exhaustively: for zero, all-ones, every
  walking-one and random words, a clean word decodes untouched, **all 128** single-bit flips are corrected, and
  **all 8128** double-bit flips are detected, never silently miscorrected (117,244 decodes).
- [`tb_ecc.sv`](tb_ecc.sv) runs through the real controller and Micron's model. A scoreboard writes words with
  0, 1 or 2 flipped bits (every one of the 128 positions for single errors) and checks the data, the flags and
  the hardware counters.

## Verification

Two independent pass criteria, because a behavioral memory model will happily store data even when timing is
violated:

1. **Functional:** read data must match what was written (a shadow-memory scoreboard)
2. **Protocol:** both Micron's built-in timing checkers and the SVA checker must report no errors

Testbench structure (the same split as UVM's sequence, scoreboard and monitor, without the library):

- **Stimulus:** `write` and `read` tasks, with directed, random and stress tests chosen by
  `+TEST=directed|random|stress`; seed set with `-sv_seed`
- **Scoreboard:** `shadow[]` holds what the DRAM should contain; `rd_q` holds the expected data for each outstanding read
- **Monitor:** checks every `rd_valid` against the scoreboard
- **Coverage counters:** refreshes issued, refresh while a request is waiting, banks hit

## Regression

`python sim/regress.py --all` builds every configuration, runs it, and writes `sim/regress/summary.md`. A design
build must pass every run. A **fault build** has a bug injected into the RTL and must fail at least one run,
which shows the checkers catch that kind of bug.

| Build | What it is | Runs passing | Result |
| --- | --- | --- | --- |
| `clean` | controller, SVA checker on | 9/9 | passes |
| `ecc` | ECC through the controller and Micron model | 10/10 | passes |
| `codec` | exhaustive SECDED codec test | 1/1 | passes |
| `selftest` | SVA checker against illegal command streams | 1/1 (25 cases) | passes |
| `buggy` | original training faults `FI_1` (tRFC), `FI_2` (column address) | 1/9 | caught by 8 runs |
| `fi_tras` | `FI_3`: PRECHARGE too soon after ACT | 0/9 | caught by all 9 |
| `fi_trcd` | `FI_4`: READ/WRITE too soon after ACT | 0/9 | caught by all 9 |
| `fi_trp` | `FI_5`: ACT too soon after PRECHARGE | 0/9 | caught by all 9 |
| `ecc_fi1`, `codec_fi1` | `FI_ECC_1`: decoder ignores overall parity (double errors miscorrected) | 2/10, 0/1 | caught |
| `ecc_fi2`, `codec_fi2` | `FI_ECC_2`: one data bit missing from a parity group | 2/10, 0/1 | caught |

The SVA checker flags the three timing faults (`FI_3`, `FI_4`, `FI_5`) in every run, independently of Micron's
model. The full table is in [`docs/regression-summary.md`](docs/regression-summary.md).

The directed controller test still passes on the original `buggy` build; only the random and stress tests catch
it, which is the case for constrained-random verification.

## Running it

The Micron DDR2 model is not redistributed here because of its license. To run the simulation:

1. Download the Micron DDR2 SDRAM Verilog model (`ddr2.v`, `ddr2_parameters.vh`) from Micron's website and place
   the files in the repository root.
2. Edit `VIV` in `sim/run_xsim.bat` if Vivado is not at `C:\Xilinx\Vivado\2020.2`.
3. Run:

```bat
sim\run_xsim.bat                 :: controller testbench, log in sim\sim.log
sim\run_xsim.bat gui             :: open waveforms
sim\run_ecc.bat                  :: ECC through the controller, with error injection
sim\run_ecc_codec.bat            :: exhaustive SECDED codec test (no DRAM model needed)
sim\run_checker_selftest.bat     :: SVA checker against illegal command streams (no DRAM model needed)
python sim\regress.py            :: controller regression, report in sim\regress\clean\report.md
python sim\regress.py --all      :: every build including injected faults
```

## Known gaps

Back-to-back requests, a request arriving the same cycle refresh becomes pending, write-then-read to the same
address with no idle gap, and reset in mid-operation are not covered yet. ECC is a separate top
(`ddr2_ecc_top`), so it is not exercised by the main controller testbench, and the controller does not write
corrected data back (no scrubbing). [`LEARNING_LOG.md`](LEARNING_LOG.md) records each step, the tool problems hit,
and the lessons learned.

## Author

Justice Rebrovich, University of North Dakota (B.S. Electrical Engineering).
