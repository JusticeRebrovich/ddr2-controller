`timescale 1ps/1ps
// ddr2_init.sv
// JEDEC DDR2 power-up and initialization sequence as a step table.
// Each step issues one command (or just holds CKE/NOP) and then waits
// wait_cyc cycles before the next step. done goes high after the last step.

module ddr2_init
  import ddr2_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  output logic                 cke,
  output cmd_t                 cmd,
  output logic [BA_BITS-1:0]   ba,
  output logic [ADDR_BITS-1:0] addr,
  output logic                 done
);

  typedef struct packed {
    logic                 cke;
    cmd_t                 cmd;
    logic [BA_BITS-1:0]   ba;
    logic [ADDR_BITS-1:0] addr;
    logic [16:0]          wait_cyc;   // cycles from this command to the next one
  } step_t;

  localparam int N_STEPS = 14;

  function automatic step_t mk(logic c, cmd_t k, int b, logic [ADDR_BITS-1:0] a, int w);
    mk = '{cke: c, cmd: k, ba: BA_BITS'(b), addr: a, wait_cyc: 17'(w)};
  endfunction

  function automatic step_t step(logic [4:0] i);
    case (i)
      //            cke   cmd      ba  addr              wait
      5'd0:  step = mk(1'b0, CMD_NOP, 0, '0,               T_INIT_CKE_LOW); // 200 us, CKE low
      5'd1:  step = mk(1'b1, CMD_NOP, 0, '0,               T_INIT_CKE_HI);  // CKE high, 400 ns
      5'd2:  step = mk(1'b1, CMD_PRE, 0, A10_ALL,          T_RPA);          // precharge all
      5'd3:  step = mk(1'b1, CMD_MRS, 2, EMR2,             T_MRD);          // EMR(2)
      5'd4:  step = mk(1'b1, CMD_MRS, 3, EMR3,             T_MRD);          // EMR(3)
      5'd5:  step = mk(1'b1, CMD_MRS, 1, EMR1_BASE,        T_MRD);          // EMR(1), DLL enable
      5'd6:  step = mk(1'b1, CMD_MRS, 0, MR_DLLRST,        T_MRD);          // MR with DLL reset
      5'd7:  step = mk(1'b1, CMD_PRE, 0, A10_ALL,          T_RPA);          // precharge all
      5'd8:  step = mk(1'b1, CMD_REF, 0, '0,               T_RFC);          // refresh 1
      5'd9:  step = mk(1'b1, CMD_REF, 0, '0,               T_RFC);          // refresh 2
      5'd10: step = mk(1'b1, CMD_MRS, 0, MR_BASE,          T_MRD);          // MR, DLL reset cleared
      5'd11: step = mk(1'b1, CMD_MRS, 1, EMR1_OCD_DEFAULT, T_MRD);          // EMR(1) OCD default
      5'd12: step = mk(1'b1, CMD_MRS, 1, EMR1_BASE,        T_MRD);          // EMR(1) OCD exit
      5'd13: step = mk(1'b1, CMD_NOP, 0, '0,               T_DLL_LOCK);     // let the DLL lock
      default: step = mk(1'b1, CMD_NOP, 0, '0, 1);
    endcase
  endfunction

  logic [4:0]  idx;
  logic [16:0] cnt;
  step_t       cur;

  always_comb cur = step(idx);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx  <= '0;
      cnt  <= '0;
      done <= 1'b0;
      cke  <= 1'b0;
      cmd  <= CMD_NOP;
      ba   <= '0;
      addr <= '0;
    end else if (!done) begin
      cmd <= CMD_NOP;                  // default: NOP between commands
      if (cnt != 0) begin
        cnt <= cnt - 1'b1;
      end else if (idx == 5'(N_STEPS)) begin
        done <= 1'b1;
      end else begin
        cke  <= cur.cke;
        cmd  <= cur.cmd;
        ba   <= cur.ba;
        addr <= cur.addr;
        cnt  <= cur.wait_cyc - 1'b1;   // next step issues exactly wait_cyc cycles later
        idx  <= idx + 1'b1;
      end
    end
  end

endmodule
