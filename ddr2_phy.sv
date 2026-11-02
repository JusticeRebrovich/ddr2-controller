`timescale 1ps/1ps
// ddr2_phy.sv
// Simulation PHY. Behavioral, not meant for synthesis.
//
// Clocks: clk drives CK. clk90 is clk delayed a quarter period (625 ps).
//
// Timeline reference: the controller registers a command on posedge n, the PHY
// launches it on negedge n (half-cycle setup and hold), and the DRAM samples it
// on posedge n+1. Call that edge T0. The shift registers below are loaded on
// T0, so after posedge T0+k, sr[k] is set.
//
// Write:  DQS preamble from T0+WL-1, DQS toggles with CK for T0+WL .. T0+WL+3.5,
//         postamble to T0+WL+4. DQ is center-aligned: it changes on clk90 edges,
//         a quarter cycle away from each DQS edge.
// Read:   DQ is sampled on clk90 edges, a quarter cycle after each expected
//         DQS edge. A real PHY would capture off a 90-degree-delayed DQS and
//         train that delay. This assumes zero board flight time.

module ddr2_phy
  import ddr2_pkg::*;
(
  input  logic                  clk,
  input  logic                  clk90,
  input  logic                  rst_n,

  // From controller
  input  logic                  cke_i,
  input  cmd_t                  cmd_i,
  input  logic [BA_BITS-1:0]    ba_i,
  input  logic [ADDR_BITS-1:0]  addr_i,
  input  logic                  wr_start,
  input  logic [BURST_BITS-1:0] wr_data,
  input  logic                  rd_start,
  output logic                  rd_valid,
  output logic [BURST_BITS-1:0] rd_data,

  // DDR2 pins
  output logic                  ck,
  output logic                  ck_n,
  output logic                  cke,
  output logic                  cs_n,
  output logic                  ras_n,
  output logic                  cas_n,
  output logic                  we_n,
  output logic                  odt,
  output logic [BA_BITS-1:0]    ba,
  output logic [ADDR_BITS-1:0]  addr,
  inout  wire  [DM_BITS-1:0]    dm_rdqs,
  inout  wire  [DQ_BITS-1:0]    dq,
  inout  wire  [DQS_BITS-1:0]   dqs,
  inout  wire  [DQS_BITS-1:0]   dqs_n
);

  // ---------------- Clock and command launch ----------------
  assign ck   = clk;
  assign ck_n = ~clk;
  assign odt  = 1'b0;   // ODT unused, Rtt disabled in EMR1

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cke                      <= 1'b0;
      {cs_n, ras_n, cas_n, we_n} <= CMD_NOP;
      ba                       <= '0;
      addr                     <= '0;
    end else begin
      cke                      <= cke_i;
      {cs_n, ras_n, cas_n, we_n} <= cmd_i;
      ba                       <= ba_i;
      addr                     <= addr_i;
    end
  end

  // ---------------- Write path ----------------
  logic [WL+3:0]         wr_sr;
  logic [BURST_BITS-1:0] wbuf;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_sr <= '0;
      wbuf  <= '0;
    end else begin
      wr_sr <= {wr_sr[WL+2:0], wr_start};
      if (wr_start) wbuf <= wr_data;
    end
  end

  // DQS output enable: preamble (k = WL-1) through postamble (k = WL+3)
  logic dqs_oe;
  assign dqs_oe = |wr_sr[WL+3:WL-1];

  // DQS toggle gate, changed on negedge so gating CK never glitches.
  // High from T0+WL-0.5 to T0+WL+3.5, which gives exactly four DQS pulses.
  logic dqs_en;
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) dqs_en <= 1'b0;
    else        dqs_en <= |wr_sr[WL+2:WL-1];
  end

  logic dqs_w;
  assign dqs_w = clk & dqs_en;

  // DQ as a DDR output: clk90 low phase shows the even beat, high phase the odd beat.
  // Each register updates during the phase it isn't being shown.
  logic [DQ_BITS-1:0] dq_even, dq_odd;
  logic               dq_oe;

  always_ff @(posedge clk90 or negedge rst_n) begin
    if (!rst_n) dq_even <= '0;
    else
      for (int c = 0; c < 4; c++)
        if (wr_sr[WL-1+c]) dq_even <= wbuf[(2*c)*DQ_BITS +: DQ_BITS];
  end

  always_ff @(negedge clk90 or negedge rst_n) begin
    if (!rst_n) begin
      dq_odd <= '0;
      dq_oe  <= 1'b0;
    end else begin
      for (int c = 0; c < 4; c++)
        if (wr_sr[WL-1+c]) dq_odd <= wbuf[(2*c+1)*DQ_BITS +: DQ_BITS];
      dq_oe <= |wr_sr[WL+2:WL-1];
    end
  end

  assign dq      = dq_oe  ? (clk90 ? dq_odd : dq_even) : 'z;
  assign dm_rdqs = dq_oe  ? '0                         : 'z;   // no byte masking
  assign dqs     = dqs_oe ? {DQS_BITS{dqs_w}}          : 'z;
  assign dqs_n   = dqs_oe ? {DQS_BITS{~dqs_w}}         : 'z;

  // ---------------- Read path ----------------
  logic [RL+4:0]      rd_sr;
  logic [DQ_BITS-1:0] rd_even [4];
  logic [DQ_BITS-1:0] rd_odd  [4];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_sr    <= '0;
      rd_valid <= 1'b0;
      rd_data  <= '0;
    end else begin
      rd_sr    <= {rd_sr[RL+3:0], rd_start};
      rd_valid <= rd_sr[RL+3];                // last beat sampled at T0+RL+3.75
      if (rd_sr[RL+3])
        for (int c = 0; c < 4; c++) begin
          rd_data[(2*c)*DQ_BITS   +: DQ_BITS] <= rd_even[c];
          rd_data[(2*c+1)*DQ_BITS +: DQ_BITS] <= rd_odd[c];
        end
    end
  end

  // Even beats follow DQS rising at T0+RL+c, sampled a quarter cycle later
  always_ff @(posedge clk90)
    for (int c = 0; c < 4; c++)
      if (rd_sr[RL+c]) rd_even[c] <= dq;

  // Odd beats follow DQS falling at T0+RL+c+0.5, sampled a quarter cycle later
  always_ff @(negedge clk90)
    for (int c = 0; c < 4; c++)
      if (rd_sr[RL+c]) rd_odd[c] <= dq;

endmodule
