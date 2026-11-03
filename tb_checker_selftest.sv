`timescale 1ps/1ps
// tb_checker_selftest.sv
// Tests the assertions themselves. A checker that never fires proves nothing, so
// this drives hand-built command sequences straight into ddr2_timing_checker:
//
//   "at limit"  : the command arrives exactly at the minimum spacing -> no failure
//   "one early" : one cycle sooner                                   -> exactly that
//                                                                       rule fails
//
// No controller and no memory model are involved. Needs only ddr2_pkg.sv and
// ddr2_timing_checker.sv.

module tb_checker_selftest;
  import ddr2_pkg::*;

  logic ck = 1'b0;
  always #1250 ck = ~ck;

  logic enable = 1'b0;
  cmd_t cmd = CMD_NOP;
  logic [BA_BITS-1:0]   ba   = '0;
  logic [ADDR_BITS-1:0] addr = '0;

  ddr2_timing_checker u_chk (
    .ck(ck), .enable(enable),
    .cs_n(cmd[3]), .ras_n(cmd[2]), .cas_n(cmd[1]), .we_n(cmd[0]),
    .ba(ba), .addr(addr)
  );

  int n_err = 0, n_cases = 0;
  int sc_cycle;

  // ---------------- Scenario helpers ----------------
  task automatic idle();
    @(negedge ck);
    cmd = CMD_NOP; addr = '0;
    sc_cycle++;
  endtask

  // Issue one command at scenario cycle c (idles until then)
  task automatic at(int c, cmd_t cm, int b = 0, bit a10 = 0);
    while (sc_cycle < c) idle();
    @(negedge ck);
    cmd = cm; ba = b; addr = '0; addr[10] = a10;
    sc_cycle++;
  endtask

  task automatic begin_case();
    enable = 1'b0;
    repeat (3) @(negedge ck);
    cmd = CMD_NOP;
    enable = 1'b1;
    sc_cycle = 0;
    @(negedge ck);
    sc_cycle = 1;
  endtask

  // Let every in-flight property finish, then compare failure counts
  task automatic check_case(string name, int rule, bit expect_fail);
    int others = 0;
    while (sc_cycle < 400) idle();
    repeat (4) @(negedge ck);
    n_cases++;
    for (int i = 0; i < u_chk.N_RULES; i++) if (i != rule) others += u_chk.fails[i];
    if (expect_fail) begin
      if (u_chk.fails[rule] == 0) begin
        n_err++; $display("ERROR [SELFTEST] %s: assertion did not fire", name);
      end else if (others != 0) begin
        n_err++; $display("ERROR [SELFTEST] %s: other rule(s) also fired (%0d)", name, others);
      end else
        $display("  ok   %-34s fired %0d time(s)", name, u_chk.fails[rule]);
    end else begin
      if (u_chk.total_fails() != 0) begin
        n_err++; $display("ERROR [SELFTEST] %s: unexpected failure(s) %0d", name, u_chk.total_fails());
      end else
        $display("  ok   %-34s clean", name);
    end
    for (int i = 0; i < u_chk.N_RULES; i++) u_chk.fails[i] = 0;
  endtask

  // ---------------- Cases: each rule, at the limit and one cycle early ----------------
  // Spec values at tCK = 2.5 ns: tRCD 5, tRP 5, tRPA 6, tRAS 16, tRC 22, tRRD 4,
  // tFAW 18, tRFC 79, RD->PRE 5, WR->PRE 14, tREFI 3120. The ACT at cycle 1 starts
  // every scenario, and a REF early in each keeps tREFI quiet.

  task automatic trcd(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(early ? 5 : 6, CMD_RD, 0); at(25, CMD_PRE, 0);
    check_case({"tRCD ", early ? "one cycle early" : "at limit"}, u_chk.R_TRCD, early);
  endtask

  task automatic tras(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(6, CMD_RD, 0); at(early ? 16 : 17, CMD_PRE, 0);
    check_case({"tRAS ", early ? "one cycle early" : "at limit"}, u_chk.R_TRAS, early);
  endtask

  task automatic trp(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(6, CMD_RD, 0); at(19, CMD_PRE, 0);
    at(early ? 23 : 24, CMD_ACT, 0);
    check_case({"tRP  ", early ? "one cycle early" : "at limit"}, u_chk.R_TRP, early);
  endtask

  task automatic trc(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(6, CMD_RD, 0); at(17, CMD_PRE, 0);
    at(early ? 22 : 23, CMD_ACT, 0);
    check_case({"tRC  ", early ? "one cycle early" : "at limit"}, u_chk.R_TRC, early);
  endtask

  task automatic trpa(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(6, CMD_RD, 0); at(17, CMD_PRE, 0, 1);       // PRECHARGE ALL
    at(early ? 22 : 23, CMD_ACT, 1);                                   // other bank
    check_case({"tRPA ", early ? "one cycle early" : "at limit"}, u_chk.R_TRPA, early);
  endtask

  task automatic trrd(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(early ? 4 : 5, CMD_ACT, 1);
    check_case({"tRRD ", early ? "one cycle early" : "at limit"}, u_chk.R_TRRD, early);
  endtask

  task automatic tfaw(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(5, CMD_ACT, 1); at(9, CMD_ACT, 2); at(13, CMD_ACT, 3);
    at(early ? 18 : 19, CMD_ACT, 4);                                   // fifth ACT
    check_case({"tFAW ", early ? "one cycle early" : "at limit"}, u_chk.R_TFAW, early);
  endtask

  task automatic trfc(bit early);
    begin_case();
    at(1, CMD_REF);
    at(early ? 79 : 80, CMD_ACT, 0);
    check_case({"tRFC ", early ? "one cycle early" : "at limit"}, u_chk.R_TRFC, early);
  endtask

  task automatic trtp(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(14, CMD_RD, 0);
    at(early ? 18 : 19, CMD_PRE, 0);                                   // tRAS long satisfied
    check_case({"tRTP ", early ? "one cycle early" : "at limit"}, u_chk.R_TRTP, early);
  endtask

  task automatic twr(bit early);
    begin_case();
    at(1, CMD_ACT, 0); at(6, CMD_WR, 0);
    at(early ? 19 : 20, CMD_PRE, 0);
    check_case({"tWR  ", early ? "one cycle early" : "at limit"}, u_chk.R_TWR, early);
  endtask

  task automatic trefi(bit early);
    begin_case();
    // the first refresh arrives well inside tREFI (3100) or clearly late (3140)
    while (sc_cycle < 3000) idle();
    at(early ? 3140 : 3100, CMD_REF);
    while (sc_cycle < 3400) idle();
    check_case({"tREFI ", early ? "refresh too late" : "at limit"}, u_chk.R_TREFI, early);
  endtask

  task automatic state_cases();
    begin_case();                                    // READ with no open row
    at(1, CMD_RD, 2);
    check_case("STATE read to closed bank", u_chk.R_STATE, 1);
    begin_case();                                    // ACT to an open bank
    at(1, CMD_ACT, 1); at(40, CMD_ACT, 1);
    check_case("STATE ACT to open bank", u_chk.R_STATE, 1);
    begin_case();                                    // REF with a bank open
    at(1, CMD_ACT, 0); at(40, CMD_REF);
    check_case("STATE REF with open bank", u_chk.R_STATE, 1);
  endtask

  // ---------------- Main ----------------
  initial begin
    $display("=== ddr2_timing_checker self-test ===");
    for (int e = 1; e >= 0; e--) begin    // early (must fire) then at-limit (must be clean)
      trcd(e); tras(e); trp(e); trc(e); trpa(e); trrd(e); tfaw(e); trfc(e); trtp(e); twr(e);
    end
    trefi(1); trefi(0);
    state_cases();
    $display("--------------------------------------------");
    $display(" %0d cases, %0d errors", n_cases, n_err);
    $display(" %s", (n_err == 0) ? "TEST PASSED" : "TEST FAILED");
    $display("--------------------------------------------");
    $finish;
  end

endmodule
