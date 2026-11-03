`timescale 1ps/1ps
// ddr2_timing_checker.sv
// SystemVerilog assertions on the DDR2 command bus. Simulation only.
//
// Watches the pins between the controller and the memory, so it checks what the
// DRAM actually sees. The limits come from the MT47H128M16 -25E datasheet in
// picoseconds and are converted to clock cycles here, independently of the
// cycle constants the controller uses in ddr2_pkg.sv. A controller constant that
// is too small therefore fails an assertion instead of agreeing with itself.
//
// Each failure prints "ERROR [SVA_<RULE>] ..." and bumps fails[RULE].
// Hold `enable` low until initialization finishes; low also clears all state.
//
// Rules checked:
//   tRCD  ACT -> RD/WR, same bank           tRP   PRE -> ACT, same bank (REF too)
//   tRPA  PRE ALL -> ACT or REF             tRAS  ACT -> PRE, same bank
//   tRC   ACT -> ACT, same bank             tRRD  ACT -> ACT, any bank
//   tFAW  at most 4 ACTs in any window      tRFC  REF -> any command
//   tRTP  RD -> PRE, same bank              tWR   WR -> PRE (write recovery)
//   tREFI REF at least every tREFI          STATE ACT to a closed bank only,
//                                                 RD/WR to an open bank only,
//                                                 REF with all banks closed

module ddr2_timing_checker
  import ddr2_pkg::*;
#(
  parameter int TCK_PS   = 2500,
  parameter int TRCD_PS  = 12500,
  parameter int TRP_PS   = 12500,
  parameter int TRPA_PS  = 15000,
  parameter int TRAS_PS  = 40000,
  parameter int TRC_PS   = 55000,
  parameter int TRRD_PS  = 10000,    // x16 (2 KB page)
  parameter int TFAW_PS  = 45000,    // x16, -25E
  parameter int TRFC_PS  = 197500,   // 2 Gb
  parameter int TRTP_PS  = 7500,
  parameter int TWR_PS   = 15000,
  parameter int TREFI_PS = 7800000
)(
  input logic                  ck,
  input logic                  enable,
  input logic                  cs_n,
  input logic                  ras_n,
  input logic                  cas_n,
  input logic                  we_n,
  input logic [BA_BITS-1:0]    ba,
  input logic [ADDR_BITS-1:0]  addr
);

  function automatic int cyc(int ps);
    return (ps + TCK_PS - 1) / TCK_PS;   // round up
  endfunction

  localparam int RCD   = cyc(TRCD_PS);
  localparam int RP    = cyc(TRP_PS);
  localparam int RPA   = cyc(TRPA_PS);
  localparam int RAS   = cyc(TRAS_PS);
  localparam int RC    = cyc(TRC_PS);
  localparam int RRD   = cyc(TRRD_PS);
  localparam int FAW   = cyc(TFAW_PS);
  localparam int RFC   = cyc(TRFC_PS);
  localparam int REFI  = TREFI_PS / TCK_PS;
  // JEDEC: RD -> PRE = AL + BL/2 + max(tRTP, 2 tCK) - 2;  WR -> PRE = WL + BL/2 + tWR
  localparam int RTP   = AL + BL/2 + ((cyc(TRTP_PS) > 2) ? cyc(TRTP_PS) : 2) - 2;
  localparam int WRPRE = WL + BL/2 + cyc(TWR_PS);

  // Rule indices for fails[]
  typedef enum int {
    R_TRCD, R_TRP, R_TRPA, R_TRAS, R_TRC, R_TRRD, R_TFAW, R_TRFC, R_TRTP, R_TWR,
    R_TREFI, R_STATE, N_RULES
  } rule_t;
  int fails [N_RULES];
  int n_act = 0, n_rd = 0, n_wr = 0, n_pre = 0, n_ref = 0;

  // ---------------- Command decode ----------------
  logic [3:0] cmd4;
  assign cmd4 = {cs_n, ras_n, cas_n, we_n};

  logic is_act, is_rd, is_wr, is_rw, is_pre, is_pre_all, is_ref, is_any;
  assign is_act     = enable && (cmd4 == 4'(CMD_ACT));
  assign is_rd      = enable && (cmd4 == 4'(CMD_RD));
  assign is_wr      = enable && (cmd4 == 4'(CMD_WR));
  assign is_rw      = is_rd || is_wr;
  assign is_pre     = enable && (cmd4 == 4'(CMD_PRE));
  assign is_pre_all = is_pre && addr[10];
  assign is_ref     = enable && (cmd4 == 4'(CMD_REF));
  assign is_any     = enable && (cmd4 != 4'(CMD_NOP)) && (cmd4 != 4'(CMD_DES));

  // ---------------- Tracked state ----------------
  logic [(1<<BA_BITS)-1:0] open_q;   // bank has an open row
  logic [FAW-1:0]          act_win;  // is_act over the last FAW cycles
  int                      since_ref;

  always_ff @(posedge ck) begin
    if (!enable) begin
      open_q    <= '0;
      act_win   <= '0;
      since_ref <= 0;
    end else begin
      act_win <= {act_win[FAW-2:0], is_act};
      if (is_act)          open_q[ba] <= 1'b1;
      else if (is_pre_all) open_q     <= '0;
      else if (is_pre)     open_q[ba] <= 1'b0;
      since_ref <= is_ref ? 0 : since_ref + 1;
      if (is_act) n_act++;
      if (is_rd)  n_rd++;
      if (is_wr)  n_wr++;
      if (is_pre) n_pre++;
      if (is_ref) n_ref++;
    end
  end

  // ---------------- Per-bank timing rules ----------------
  genvar b;
  generate
    for (b = 0; b < (1<<BA_BITS); b++) begin : g_bank
      logic act_b, rw_b, pre_b, rd_b, wr_b, pre_hit_b;
      assign act_b     = is_act && (ba == b);
      assign rd_b      = is_rd  && (ba == b);
      assign wr_b      = is_wr  && (ba == b);
      assign rw_b      = is_rw  && (ba == b);
      assign pre_hit_b = is_pre && ((ba == b) || addr[10]);   // single-bank or all-bank

      a_trcd: assert property (@(posedge ck) disable iff (!enable)
          act_b |=> (!rw_b)[*RCD-1])
        else begin fails[R_TRCD]++;
          $display("[%0t] ERROR [SVA_TRCD] bank %0d: READ/WRITE before tRCD (%0d cycles) elapsed after ACT", $time, b, RCD); end

      a_tras: assert property (@(posedge ck) disable iff (!enable)
          act_b |=> (!pre_hit_b)[*RAS-1])
        else begin fails[R_TRAS]++;
          $display("[%0t] ERROR [SVA_TRAS] bank %0d: PRECHARGE before tRAS (%0d cycles) elapsed", $time, b, RAS); end

      a_trc: assert property (@(posedge ck) disable iff (!enable)
          act_b |=> (!act_b)[*RC-1])
        else begin fails[R_TRC]++;
          $display("[%0t] ERROR [SVA_TRC] bank %0d: ACT before tRC (%0d cycles) elapsed", $time, b, RC); end

      a_trp: assert property (@(posedge ck) disable iff (!enable)
          (is_pre && (ba == b)) |=> (!act_b)[*RP-1])
        else begin fails[R_TRP]++;
          $display("[%0t] ERROR [SVA_TRP] bank %0d: ACT before tRP (%0d cycles) after PRECHARGE", $time, b, RP); end

      a_trpa: assert property (@(posedge ck) disable iff (!enable)
          is_pre_all |=> (!act_b)[*RPA-1])
        else begin fails[R_TRPA]++;
          $display("[%0t] ERROR [SVA_TRPA] bank %0d: ACT before tRPA (%0d cycles) after PRECHARGE ALL", $time, b, RPA); end

      a_trtp: assert property (@(posedge ck) disable iff (!enable)
          rd_b |=> (!pre_hit_b)[*RTP-1])
        else begin fails[R_TRTP]++;
          $display("[%0t] ERROR [SVA_TRTP] bank %0d: PRECHARGE before read-to-precharge (%0d cycles) elapsed", $time, b, RTP); end

      a_twr: assert property (@(posedge ck) disable iff (!enable)
          wr_b |=> (!pre_hit_b)[*WRPRE-1])
        else begin fails[R_TWR]++;
          $display("[%0t] ERROR [SVA_TWR] bank %0d: PRECHARGE before write recovery (%0d cycles)", $time, b, WRPRE); end

      // Bank state rules
      a_act_closed: assert property (@(posedge ck) disable iff (!enable)
          act_b |-> !open_q[b])
        else begin fails[R_STATE]++;
          $display("[%0t] ERROR [SVA_STATE] ACT to bank %0d which already has an open row", $time, b); end

      a_rw_open: assert property (@(posedge ck) disable iff (!enable)
          rw_b |-> open_q[b])
        else begin fails[R_STATE]++;
          $display("[%0t] ERROR [SVA_STATE] READ/WRITE to bank %0d with no open row", $time, b); end
    end
  endgenerate

  // ---------------- Global rules ----------------
  a_trrd: assert property (@(posedge ck) disable iff (!enable)
      is_act |=> (!is_act)[*RRD-1])
    else begin fails[R_TRRD]++;
      $display("[%0t] ERROR [SVA_TRRD] ACT before tRRD (%0d cycles) after the previous ACT", $time, RRD); end

  a_tfaw: assert property (@(posedge ck) disable iff (!enable)
      $countones({act_win[FAW-2:0], is_act}) <= 4)
    else begin fails[R_TFAW]++;
      $display("[%0t] ERROR [SVA_TFAW] more than 4 ACTs within tFAW (%0d cycles)", $time, FAW); end

  a_trfc: assert property (@(posedge ck) disable iff (!enable)
      is_ref |=> (!is_any)[*RFC-1])
    else begin fails[R_TRFC]++;
      $display("[%0t] ERROR [SVA_TRFC] command before tRFC (%0d cycles) after REFRESH", $time, RFC); end

  a_pre_ref: assert property (@(posedge ck) disable iff (!enable)
      is_pre |=> (!is_ref)[*RP-1])
    else begin fails[R_TRP]++;
      $display("[%0t] ERROR [SVA_TRP] REFRESH before tRP (%0d cycles) after PRECHARGE", $time, RP); end

  a_preall_ref: assert property (@(posedge ck) disable iff (!enable)
      is_pre_all |=> (!is_ref)[*RPA-1])
    else begin fails[R_TRPA]++;
      $display("[%0t] ERROR [SVA_TRPA] REFRESH before tRPA (%0d cycles) after PRECHARGE ALL", $time, RPA); end

  a_ref_idle: assert property (@(posedge ck) disable iff (!enable)
      is_ref |-> (open_q == '0))
    else begin fails[R_STATE]++;
      $display("[%0t] ERROR [SVA_STATE] REFRESH with a bank still open (open=%b)", $time, open_q); end

  a_trefi: assert property (@(posedge ck) disable iff (!enable)
      since_ref != REFI + 1)          // fires once, on the first cycle past tREFI
    else begin fails[R_TREFI]++;
      $display("[%0t] ERROR [SVA_TREFI] no REFRESH within tREFI (%0d cycles)", $time, REFI); end

  // ---------------- Reporting ----------------
  function automatic int total_fails();
    int t = 0;
    for (int i = 0; i < N_RULES; i++) t += fails[i];
    return t;
  endfunction

  function automatic void summary();
    $display(" timing checker: ACT=%0d RD=%0d WR=%0d PRE=%0d REF=%0d, %0d assertion failure(s)",
             n_act, n_rd, n_wr, n_pre, n_ref, total_fails());
  endfunction

  initial for (int i = 0; i < N_RULES; i++) fails[i] = 0;

endmodule
