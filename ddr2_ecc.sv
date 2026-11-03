`timescale 1ps/1ps
// ddr2_ecc.sv
// SECDED error correction for the DDR2 controller: single-error correct,
// double-error detect.
//
// Code: extended Hamming (128,120). One DDR2 burst is 128 bits (BL8 x 16), so a
// burst carries 120 data bits plus 8 check bits and no extra DRAM lane is needed.
//
//   codeword bit 0        overall parity of bits 127:1
//   codeword bits 1..127  Hamming code; the 7 check bits sit at positions 1,2,4,...,64
//                         and the 120 data bits fill the other positions in order
//
// Decoding: the syndrome (XOR of the positions of all set bits in 1..127) names the
// flipped bit, and the overall parity separates one error from two.
//   syndrome 0, parity ok     no error
//   parity bad                single error, corrected (syndrome 0 = the parity bit itself)
//   syndrome != 0, parity ok  double error, detected and NOT corrected
// Three or more errors can be miscorrected, as with any SECDED code.
//
// Fault-injection defines (sim/regress.py only): FI_ECC_1, FI_ECC_2.

package ddr2_ecc_pkg;

  localparam int ECC_DATA_BITS = 120;
  localparam int ECC_CODE_BITS = 128;
  localparam int ECC_CHECK     = 7;     // Hamming check bits, plus the overall parity bit

  typedef struct packed {
    logic [ECC_DATA_BITS-1:0] data;
    logic                     sbe;      // single error, corrected
    logic                     dbe;      // double error, detected (data not trustworthy)
  } ecc_result_t;

  function automatic bit is_pow2(int n);
    return (n & (n - 1)) == 0;
  endfunction

  function automatic logic [ECC_CODE_BITS-1:0] ecc_encode(input logic [ECC_DATA_BITS-1:0] d);
    logic [ECC_CODE_BITS-1:0] cw;
    int  k;
    bit  p;
    cw = '0;
    k  = 0;
    for (int pos = 1; pos < ECC_CODE_BITS; pos++)
      if (!is_pow2(pos)) begin
        cw[pos] = d[k];
        k++;
      end
    for (int i = 0; i < ECC_CHECK; i++) begin
      p = 1'b0;
      for (int pos = 1; pos < ECC_CODE_BITS; pos++)
        if (pos[i] && !is_pow2(pos)
`ifdef FI_ECC_2   // fault injection: data bit at position 11 is left out of parity group 3
            && !(i == 3 && pos == 11)
`endif
           ) p ^= cw[pos];
      cw[1 << i] = p;
    end
    cw[0] = ^cw[ECC_CODE_BITS-1:1];
    return cw;
  endfunction

  function automatic ecc_result_t ecc_decode(input logic [ECC_CODE_BITS-1:0] cw_in);
    logic [ECC_CODE_BITS-1:0] cw;
    logic [ECC_CHECK-1:0]     syn;
    logic                     par;
    ecc_result_t              r;
    int                       k;
    bit                       p;

    cw = cw_in;
    for (int i = 0; i < ECC_CHECK; i++) begin
      p = 1'b0;
      for (int pos = 1; pos < ECC_CODE_BITS; pos++)
        if (pos[i]) p ^= cw[pos];
      syn[i] = p;
    end
    par   = ^cw;
    r.sbe = 1'b0;
    r.dbe = 1'b0;

`ifdef FI_ECC_1   // fault injection: overall parity ignored, double errors get miscorrected
    if (syn != 0) begin
      cw[syn] = ~cw[syn];
      r.sbe   = 1'b1;
    end else if (par) begin
      cw[0] = ~cw[0];
      r.sbe = 1'b1;
    end
`else
    if (par) begin
      cw[syn] = ~cw[syn];          // syn == 0 flips the overall parity bit, data untouched
      r.sbe   = 1'b1;
    end else if (syn != 0) begin
      r.dbe = 1'b1;
    end
`endif

    k = 0;
    for (int pos = 1; pos < ECC_CODE_BITS; pos++)
      if (!is_pow2(pos)) begin
        r.data[k] = cw[pos];
        k++;
      end
    return r;
  endfunction

endpackage


// ECC wrapper around the controller. User data is 120 bits per burst.
// inj_mask is XORed into the codeword as it is written, which models bits that
// went bad in storage. Hold it with the request; the controller latches the
// write data on the cycle it accepts the request.
module ddr2_ecc_top
  import ddr2_pkg::*;
  import ddr2_ecc_pkg::*;
(
  input  logic                     clk,
  input  logic                     clk90,
  input  logic                     rst_n,

  // User side
  input  logic                     req_valid,
  output logic                     req_ready,
  input  logic                     req_we,
  input  logic [UADDR_BITS-1:0]    req_addr,
  input  logic [ECC_DATA_BITS-1:0] req_wdata,
  input  logic [ECC_CODE_BITS-1:0] inj_mask,     // error injection, 0 = none
  output logic                     rd_valid,
  output logic [ECC_DATA_BITS-1:0] rd_data,
  output logic                     rd_sbe,       // valid with rd_valid
  output logic                     rd_dbe,
  output logic [31:0]              sbe_count,
  output logic [31:0]              dbe_count,
  output logic                     init_done,

  // DDR2 pins
  output logic                     ck,
  output logic                     ck_n,
  output logic                     cke,
  output logic                     cs_n,
  output logic                     ras_n,
  output logic                     cas_n,
  output logic                     we_n,
  output logic                     odt,
  output logic [BA_BITS-1:0]       ba,
  output logic [ADDR_BITS-1:0]     addr,
  inout  wire  [DM_BITS-1:0]       dm_rdqs,
  inout  wire  [DQ_BITS-1:0]       dq,
  inout  wire  [DQS_BITS-1:0]      dqs,
  inout  wire  [DQS_BITS-1:0]      dqs_n
);

  initial assert (BURST_BITS == ECC_CODE_BITS)
    else $fatal(1, "ECC codeword (%0d) must equal the burst (%0d)", ECC_CODE_BITS, BURST_BITS);

  logic [BURST_BITS-1:0] c_wdata, c_rdata;
  logic                  c_rd_valid;

  assign c_wdata = ecc_encode(req_wdata) ^ inj_mask;

  ddr2_top u_core (
    .clk(clk), .clk90(clk90), .rst_n(rst_n),
    .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
    .req_addr(req_addr), .req_wdata(c_wdata),
    .rd_valid(c_rd_valid), .rd_data(c_rdata), .init_done(init_done),
    .ck(ck), .ck_n(ck_n), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .odt(odt), .ba(ba), .addr(addr),
    .dm_rdqs(dm_rdqs), .dq(dq), .dqs(dqs), .dqs_n(dqs_n)
  );

  // Decode and register: data, flags and valid stay aligned, one cycle after the core
  ecc_result_t dec;
  assign dec = ecc_decode(c_rdata);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid  <= 1'b0;
      rd_data   <= '0;
      rd_sbe    <= 1'b0;
      rd_dbe    <= 1'b0;
      sbe_count <= '0;
      dbe_count <= '0;
    end else begin
      rd_valid <= c_rd_valid;
      rd_data  <= dec.data;
      rd_sbe   <= c_rd_valid & dec.sbe;
      rd_dbe   <= c_rd_valid & dec.dbe;
      if (c_rd_valid && dec.sbe) sbe_count <= sbe_count + 1'b1;
      if (c_rd_valid && dec.dbe) dbe_count <= dbe_count + 1'b1;
    end
  end

endmodule
