`timescale 1ps/1ps
// ddr2_pkg.sv
// Constants for MT47H128M16 (2Gb x16), speed grade -25E, run at tCK = 2.5 ns.
// Every timing value is in clock cycles, rounded up. Check these against
// your own timing table and the sg25E block of ddr2_parameters.vh.

package ddr2_pkg;

  // ---------------- Geometry ----------------
  localparam int BA_BITS    = 3;    // 8 banks
  localparam int ROW_BITS   = 14;
  localparam int COL_BITS   = 10;
  localparam int ADDR_BITS  = 14;   // confirm ADDR_BITS in ddr2_parameters.vh
  localparam int DQ_BITS    = 16;
  localparam int DQS_BITS   = 2;
  localparam int DM_BITS    = 2;
  localparam int BL         = 8;
  localparam int BURST_BITS = BL * DQ_BITS;                  // 128 bits per burst
  localparam int UADDR_BITS = ROW_BITS + BA_BITS + COL_BITS; // user address {row, bank, col}

  // ---------------- Latencies ----------------
  localparam int CL = 5;
  localparam int AL = 0;
  localparam int RL = AL + CL;   // 5
  localparam int WL = RL - 1;    // 4

  // ---------------- Core timing (cycles @ 2.5 ns) ----------------
  localparam int T_RCD  = 5;     // 12.5 ns
  localparam int T_RP   = 5;     // 12.5 ns
  localparam int T_RPA  = 6;     // 15 ns, precharge-all on an 8-bank part
  localparam int T_RAS  = 18;    // 45 ns
  localparam int T_RC   = 22;    // 55 ns
  localparam int T_RFC  = 79;    // 197.5 ns for 2Gb
  localparam int T_WR   = 6;     // 15 ns
  localparam int T_RTP  = 3;     // 7.5 ns
  localparam int T_MRD  = 2;     // tCK
  localparam int T_REFI = 3120;  // 7.8 us
  localparam int REF_MARGIN = 64; // issue refresh a little early so a busy FSM can't push it past tREFI

  // tWTR, tRRD and tFAW are not tracked yet. The closed-page FSM below only ever
  // has one row open and one access in flight, so it can't violate them.
  // They become real once you add open-page or bank interleaving.

  // ---------------- Init waits ----------------
  localparam int T_INIT_CKE_LOW = 80000; // 200 us with stable clock, CKE low
  localparam int T_INIT_CKE_HI  = 160;   // 400 ns after CKE high before PRE ALL
  localparam int T_DLL_LOCK     = 200;   // cycles after DLL reset before any READ

  // ---------------- Derived command spacing ----------------
  localparam int WR_TO_PRE = WL + BL/2 + T_WR;                      // 14
  localparam int RD_TO_PRE = AL + BL/2 + ((T_RTP > 2) ? T_RTP : 2) - 2; // 5

  // ---------------- Commands: {cs_n, ras_n, cas_n, we_n} ----------------
  typedef enum logic [3:0] {
    CMD_MRS = 4'b0000,
    CMD_REF = 4'b0001,
    CMD_PRE = 4'b0010,
    CMD_ACT = 4'b0011,
    CMD_WR  = 4'b0100,
    CMD_RD  = 4'b0101,
    CMD_NOP = 4'b0111,
    CMD_DES = 4'b1111
  } cmd_t;

  // ---------------- Mode register values ----------------
  // MR:  A12 PD=0 | A11:9 WR=6 (101) | A8 DLL reset | A7 TM=0 | A6:4 CL=5 (101) | A3 BT=seq | A2:0 BL=8 (011)
  localparam logic [ADDR_BITS-1:0] MR_BASE   = 14'b00_101_0_0_101_0_011;
  localparam logic [ADDR_BITS-1:0] MR_DLLRST = MR_BASE | 14'h0100;

  // EMR1: DLL enabled, full drive, Rtt off, AL=0, OCD exit, DQS# enabled, RDQS off, outputs on
  localparam logic [ADDR_BITS-1:0] EMR1_BASE        = 14'h0000;
  localparam logic [ADDR_BITS-1:0] EMR1_OCD_DEFAULT = 14'h0380; // A9:7 = 111

  localparam logic [ADDR_BITS-1:0] EMR2 = 14'h0000;
  localparam logic [ADDR_BITS-1:0] EMR3 = 14'h0000;

  // Precharge-all is PRE with A10 high
  localparam logic [ADDR_BITS-1:0] A10_ALL = 14'h0400;

endpackage
