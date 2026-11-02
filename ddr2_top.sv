`timescale 1ps/1ps
// ddr2_top.sv
// Controller + PHY. This is what the testbench instantiates next to Micron's ddr2 model.

module ddr2_top
  import ddr2_pkg::*;
(
  input  logic                  clk,
  input  logic                  clk90,
  input  logic                  rst_n,

  // User side
  input  logic                  req_valid,
  output logic                  req_ready,
  input  logic                  req_we,
  input  logic [UADDR_BITS-1:0] req_addr,
  input  logic [BURST_BITS-1:0] req_wdata,
  output logic                  rd_valid,
  output logic [BURST_BITS-1:0] rd_data,
  output logic                  init_done,

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

  logic                  c_cke;
  cmd_t                  c_cmd;
  logic [BA_BITS-1:0]    c_ba;
  logic [ADDR_BITS-1:0]  c_addr;
  logic                  c_wr_start;
  logic [BURST_BITS-1:0] c_wr_data;
  logic                  c_rd_start;

  ddr2_ctrl u_ctrl (
    .clk      (clk),
    .rst_n    (rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_we   (req_we),
    .req_addr (req_addr),
    .req_wdata(req_wdata),
    .init_done(init_done),
    .cke      (c_cke),
    .cmd      (c_cmd),
    .ba       (c_ba),
    .addr     (c_addr),
    .wr_start (c_wr_start),
    .wr_data  (c_wr_data),
    .rd_start (c_rd_start)
  );

  ddr2_phy u_phy (
    .clk     (clk),
    .clk90   (clk90),
    .rst_n   (rst_n),
    .cke_i   (c_cke),
    .cmd_i   (c_cmd),
    .ba_i    (c_ba),
    .addr_i  (c_addr),
    .wr_start(c_wr_start),
    .wr_data (c_wr_data),
    .rd_start(c_rd_start),
    .rd_valid(rd_valid),
    .rd_data (rd_data),
    .ck      (ck),
    .ck_n    (ck_n),
    .cke     (cke),
    .cs_n    (cs_n),
    .ras_n   (ras_n),
    .cas_n   (cas_n),
    .we_n    (we_n),
    .odt     (odt),
    .ba      (ba),
    .addr    (addr),
    .dm_rdqs (dm_rdqs),
    .dq      (dq),
    .dqs     (dqs),
    .dqs_n   (dqs_n)
  );

endmodule
