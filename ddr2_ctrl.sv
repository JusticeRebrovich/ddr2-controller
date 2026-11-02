`timescale 1ps/1ps
// ddr2_ctrl.sv
// Command scheduler. Closed-page policy, one request at a time:
//   ACT -> (tRCD) -> WRITE/READ -> (write or read recovery, tRAS) -> PRE -> (tRP) -> idle
// Refresh is issued from idle every tREFI (minus a margin), with all banks already closed.
// Until init finishes, the init sequencer owns the command bus.

module ddr2_ctrl
  import ddr2_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,

  // User side. One request = one BL8 burst (128 bits).
  input  logic                   req_valid,
  output logic                   req_ready,
  input  logic                   req_we,
  input  logic [UADDR_BITS-1:0]  req_addr,    // {row, bank, col}, col[2:0] ignored
  input  logic [BURST_BITS-1:0]  req_wdata,
  output logic                   init_done,

  // To the PHY. All registered on posedge clk.
  output logic                   cke,
  output cmd_t                   cmd,
  output logic [BA_BITS-1:0]     ba,
  output logic [ADDR_BITS-1:0]   addr,
  output logic                   wr_start,    // pulses with the WRITE command
  output logic [BURST_BITS-1:0]  wr_data,
  output logic                   rd_start     // pulses with the READ command
);

  // ---------------- Init sequencer ----------------
  logic                 init_cke;
  cmd_t                 init_cmd;
  logic [BA_BITS-1:0]   init_ba;
  logic [ADDR_BITS-1:0] init_addr;

  ddr2_init u_init (
    .clk  (clk),
    .rst_n(rst_n),
    .cke  (init_cke),
    .cmd  (init_cmd),
    .ba   (init_ba),
    .addr (init_addr),
    .done (init_done)
  );

  // ---------------- Scheduler state ----------------
  typedef enum logic [1:0] {S_IDLE, S_COL, S_PRE} state_t;
  state_t state;

  cmd_t                 s_cmd;
  logic [BA_BITS-1:0]   s_ba;
  logic [ADDR_BITS-1:0] s_addr;

  logic [7:0]  wait_cnt;   // cycles until the next command is allowed
  logic [7:0]  tras_cnt;   // ACT -> PRE minimum
  logic [7:0]  trc_cnt;    // ACT -> ACT / REF minimum
  logic [11:0] ref_timer;
  logic        ref_pending;

  // Latched request
  logic                  cur_we;
  logic [BA_BITS-1:0]    cur_ba;
  logic [COL_BITS-1:0]   cur_col;
  logic [BURST_BITS-1:0] cur_wdata;

  logic can_issue;
  assign can_issue = (wait_cnt == 0) && (trc_cnt == 0);
  assign req_ready = init_done && (state == S_IDLE) && can_issue && !ref_pending;

  // User address split
  logic [COL_BITS-1:0] u_col;
  logic [BA_BITS-1:0]  u_ba;
  logic [ROW_BITS-1:0] u_row;
  assign u_col = req_addr[COL_BITS-1:0];
  assign u_ba  = req_addr[COL_BITS +: BA_BITS];
  assign u_row = req_addr[COL_BITS+BA_BITS +: ROW_BITS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      s_cmd       <= CMD_NOP;
      s_ba        <= '0;
      s_addr      <= '0;
      wait_cnt    <= '0;
      tras_cnt    <= '0;
      trc_cnt     <= '0;
      ref_timer   <= '0;
      ref_pending <= 1'b0;
      wr_start    <= 1'b0;
      rd_start    <= 1'b0;
      cur_we      <= 1'b0;
      cur_ba      <= '0;
      cur_col     <= '0;
      cur_wdata   <= '0;
    end else begin
      // Defaults every cycle
      s_cmd    <= CMD_NOP;
      wr_start <= 1'b0;
      rd_start <= 1'b0;

      if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
      if (tras_cnt != 0) tras_cnt <= tras_cnt - 1'b1;
      if (trc_cnt  != 0) trc_cnt  <= trc_cnt  - 1'b1;

      if (!init_done) begin
        ref_timer   <= 12'(T_REFI - REF_MARGIN - 1);
        ref_pending <= 1'b0;
      end else begin
        case (state)
          // ---------------------------------------------------------
          S_IDLE: if (can_issue) begin
            if (ref_pending) begin
              s_cmd       <= CMD_REF;
`ifdef FI_1   // training fault injection, off by default
              wait_cnt    <= 8'(T_RP - 1);
`else
              wait_cnt    <= 8'(T_RFC - 1);
`endif
              ref_pending <= 1'b0;
            end else if (req_valid) begin
              cur_we    <= req_we;
              cur_ba    <= u_ba;
              cur_col   <= u_col;
              cur_wdata <= req_wdata;

              s_cmd    <= CMD_ACT;
              s_ba     <= u_ba;
              s_addr   <= u_row;
              wait_cnt <= 8'(T_RCD - 1);
              tras_cnt <= 8'(T_RAS - 1);
              trc_cnt  <= 8'(T_RC - 1);
              state    <= S_COL;
            end
          end
          // ---------------------------------------------------------
          S_COL: if (wait_cnt == 0) begin
            s_cmd  <= cur_we ? CMD_WR : CMD_RD;
            s_ba   <= cur_ba;
            s_addr <= '0;                                     // A10 = 0, no auto-precharge
`ifdef FI_2   // training fault injection, off by default
            s_addr[COL_BITS-1:4] <= cur_col[COL_BITS-1:4];
`else
            s_addr[COL_BITS-1:3] <= cur_col[COL_BITS-1:3];    // BL8 aligned
`endif
            if (cur_we) begin
              wr_start <= 1'b1;
              wait_cnt <= 8'(WR_TO_PRE - 1);
            end else begin
              rd_start <= 1'b1;
              wait_cnt <= 8'(RD_TO_PRE - 1);
            end
            state <= S_PRE;
          end
          // ---------------------------------------------------------
          S_PRE: if (wait_cnt == 0 && tras_cnt == 0) begin
            s_cmd    <= CMD_PRE;
            s_ba     <= cur_ba;
            s_addr   <= '0;                                   // A10 = 0, this bank only
            wait_cnt <= 8'(T_RP - 1);
            state    <= S_IDLE;
          end
          default: state <= S_IDLE;
        endcase

        // Refresh timer. Placed after the case so a new request for refresh
        // wins if it lands on the same cycle one is being issued.
        if (ref_timer == 0) begin
          ref_timer   <= 12'(T_REFI - REF_MARGIN - 1);
          ref_pending <= 1'b1;
        end else begin
          ref_timer <= ref_timer - 1'b1;
        end
      end
    end
  end

  // ---------------- Output mux ----------------
  assign cke     = init_done ? 1'b1   : init_cke;
  assign cmd     = init_done ? s_cmd  : init_cmd;
  assign ba      = init_done ? s_ba   : init_ba;
  assign addr    = init_done ? s_addr : init_addr;
  assign wr_data = cur_wdata;

endmodule
