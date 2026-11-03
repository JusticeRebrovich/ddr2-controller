`timescale 1ps/1ps
// tb_ecc.sv
// System-level ECC test: ddr2_ecc_top + Micron's DDR2 model, with error injection.
//
// A word is written with a chosen number of bits flipped in the stored codeword
// (inj_mask), then read back. The scoreboard knows how many bits it flipped, so it
// knows what the controller must report:
//   0 flipped bits  data correct, no flags
//   1 flipped bit   data CORRECTED, sbe=1, dbe=0
//   2 flipped bits  dbe=1, sbe=0   (data is not trustworthy and is not compared)
// At the end the sbe/dbe counters must equal what the scoreboard saw.
//
// Plusargs: +TEST=clean|single|double|random|all (default all)   +N_OPS=<n>
// The random seed comes from the simulator: xsim -sv_seed <n>.
// The SVA timing checker watches the command pins the whole time.

module tb_ecc;
  import ddr2_pkg::*;
  import ddr2_ecc_pkg::*;

  localparam int TCK = 2500;
  logic clk = 1'b0, clk90 = 1'b0, rst_n = 1'b0;
  always #(TCK/2) clk = ~clk;
  initial begin #(TCK/4); forever #(TCK/2) clk90 = ~clk90; end
  initial begin repeat (10) @(posedge clk); rst_n = 1'b1; end

  logic                     req_valid = 1'b0, req_we = 1'b0;
  logic                     req_ready;
  logic [UADDR_BITS-1:0]    req_addr  = '0;
  logic [ECC_DATA_BITS-1:0] req_wdata = '0;
  logic [ECC_CODE_BITS-1:0] inj_mask  = '0;
  logic                     rd_valid, rd_sbe, rd_dbe, init_done;
  logic [ECC_DATA_BITS-1:0] rd_data;
  logic [31:0]              sbe_count, dbe_count;

  wire                   ck, ck_n, cke, cs_n, ras_n, cas_n, we_n, odt;
  wire [BA_BITS-1:0]     ba;
  wire [ADDR_BITS-1:0]   addr;
  wire [DM_BITS-1:0]     dm_rdqs;
  wire [DQ_BITS-1:0]     dq;
  wire [DQS_BITS-1:0]    dqs, dqs_n, rdqs_n;

  ddr2_ecc_top u_dut (
    .clk(clk), .clk90(clk90), .rst_n(rst_n),
    .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
    .req_addr(req_addr), .req_wdata(req_wdata), .inj_mask(inj_mask),
    .rd_valid(rd_valid), .rd_data(rd_data), .rd_sbe(rd_sbe), .rd_dbe(rd_dbe),
    .sbe_count(sbe_count), .dbe_count(dbe_count), .init_done(init_done),
    .ck(ck), .ck_n(ck_n), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .odt(odt), .ba(ba), .addr(addr),
    .dm_rdqs(dm_rdqs), .dq(dq), .dqs(dqs), .dqs_n(dqs_n)
  );

  ddr2 u_mem (
    .ck(ck), .ck_n(ck_n), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .dm_rdqs(dm_rdqs), .ba(ba), .addr(addr), .dq(dq), .dqs(dqs),
    .dqs_n(dqs_n), .rdqs_n(rdqs_n), .odt(odt)
  );

  ddr2_timing_checker u_chk (
    .ck(ck), .enable(init_done),
    .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .ba(ba), .addr(addr)
  );

  // ---------------- Reporting ----------------
  string test_name = "all";
  int    n_ops     = 300;
  int    n_errors  = 0;

  function automatic void error(string id, string msg);
    n_errors++;
    if (n_errors <= 30) $display("[%0t] ERROR [%s] %s", $time, id, msg);
  endfunction

  function automatic logic [UADDR_BITS-1:0] mkaddr(int row, int bank, int col);
    return {ROW_BITS'(row), BA_BITS'(bank), COL_BITS'(col & ~7)};
  endfunction

  // ---------------- Scoreboard ----------------
  typedef struct {
    logic [UADDR_BITS-1:0]    addr;
    logic [ECC_DATA_BITS-1:0] data;
    int                       flips;   // bits flipped when it was written
  } exp_t;

  logic [ECC_DATA_BITS-1:0] shadow [logic [UADDR_BITS-1:0]];
  int                       flips_at [logic [UADDR_BITS-1:0]];
  exp_t                     rd_q [$];
  int n_wr = 0, n_rd = 0, n_clean = 0, n_sbe = 0, n_dbe = 0;

  always @(negedge clk) if (rst_n && rd_valid) begin
    exp_t e;
    if (rd_q.size() == 0) begin
      error("ECC_SCB", "read data returned with no read outstanding");
    end else begin
      e = rd_q.pop_front();
      case (e.flips)
        0: begin
          n_clean++;
          if (rd_data !== e.data) error("ECC_DATA", $sformatf("clean word wrong, exp=%h got=%h", e.data, rd_data));
          if (rd_sbe || rd_dbe)   error("ECC_FLAG", $sformatf("flags on a clean word: sbe=%b dbe=%b", rd_sbe, rd_dbe));
        end
        1: begin
          n_sbe++;
          if (rd_data !== e.data) error("ECC_CORRECT", $sformatf("single error NOT corrected, exp=%h got=%h", e.data, rd_data));
          if (!rd_sbe || rd_dbe)  error("ECC_FLAG", $sformatf("single error flags wrong: sbe=%b dbe=%b", rd_sbe, rd_dbe));
        end
        default: begin
          n_dbe++;
          if (!rd_dbe || rd_sbe)  error("ECC_DETECT", $sformatf("double error not detected: sbe=%b dbe=%b", rd_sbe, rd_dbe));
        end
      endcase
    end
  end

  // ---------------- Stimulus ----------------
  task automatic send(input logic we, input logic [UADDR_BITS-1:0] a,
                      input logic [ECC_DATA_BITS-1:0] d, input logic [ECC_CODE_BITS-1:0] mask);
    @(negedge clk);
    req_valid = 1'b1; req_we = we; req_addr = a; req_wdata = d; inj_mask = mask;
    while (!req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0; inj_mask = '0;
  endtask

  function automatic logic [ECC_DATA_BITS-1:0] rand120();
    logic [127:0] t;
    t = {$urandom, $urandom, $urandom, $urandom};
    return t[ECC_DATA_BITS-1:0];
  endfunction

  // Mask with `flips` distinct random bits set (positions anywhere in the codeword)
  function automatic logic [ECC_CODE_BITS-1:0] rand_mask(int flips);
    logic [ECC_CODE_BITS-1:0] m = '0;
    int p;
    while ($countones(m) < flips) begin
      p = $urandom_range(0, ECC_CODE_BITS-1);
      m[p] = 1'b1;
    end
    return m;
  endfunction

  task automatic write(input logic [UADDR_BITS-1:0] a, input logic [ECC_DATA_BITS-1:0] d,
                       input logic [ECC_CODE_BITS-1:0] mask);
    send(1'b1, a, d, mask);
    shadow[a]   = d;
    flips_at[a] = $countones(mask);
    n_wr++;
  endtask

  task automatic read(input logic [UADDR_BITS-1:0] a);
    send(1'b0, a, '0, '0);
    rd_q.push_back('{addr: a, data: shadow[a], flips: flips_at[a]});
    n_rd++;
  endtask

  function automatic logic [UADDR_BITS-1:0] pick_addr();
    return mkaddr($urandom_range(0, 2**ROW_BITS-1), $urandom_range(0, 7), 8*$urandom_range(0, 100));
  endfunction

  // ---------------- Tests ----------------
  task automatic run_clean(int n);
    for (int i = 0; i < n; i++) begin
      logic [UADDR_BITS-1:0] a = pick_addr();
      write(a, rand120(), '0);
      read(a);
    end
  endtask

  // Every one of the 128 codeword bits, data bits, check bits and parity bit alike
  task automatic run_single();
    for (int p = 0; p < ECC_CODE_BITS; p++) begin
      logic [UADDR_BITS-1:0] a = pick_addr();
      write(a, rand120(), ECC_CODE_BITS'(1) << p);
      read(a);
    end
  endtask

  task automatic run_double(int n);
    for (int i = 0; i < n; i++) begin
      logic [UADDR_BITS-1:0] a = pick_addr();
      write(a, rand120(), rand_mask(2));
      read(a);
    end
  endtask

  // Random mix of 0, 1 and 2 flipped bits, with reads of earlier writes
  task automatic run_random(int n);
    for (int i = 0; i < n; i++) begin
      logic [UADDR_BITS-1:0] a = pick_addr();
      int flips;
      case ($urandom_range(0, 9))
        0,1,2,3: flips = 0;
        4,5,6,7: flips = 1;
        default: flips = 2;
      endcase
      write(a, rand120(), rand_mask(flips));
      read(a);
      if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 40)) @(negedge clk);
    end
  endtask

  // ---------------- Main ----------------
  initial begin
    bit found;
    found = $value$plusargs("TEST=%s",  test_name);
    found = $value$plusargs("N_OPS=%d", n_ops);
    $display("[%0t] test=%s n_ops=%0d", $time, test_name, n_ops);

    wait (init_done);
    @(posedge clk);

    if (test_name == "all" || test_name == "clean")  run_clean(40);
    if (test_name == "all" || test_name == "single") run_single();
    if (test_name == "all" || test_name == "double") run_double(120);
    if (test_name == "all" || test_name == "random") run_random(n_ops);

    fork
      wait (rd_q.size() == 0);
      repeat (1000) @(posedge clk);
    join_any
    disable fork;
    if (rd_q.size() != 0) error("ECC_SCB", $sformatf("%0d read(s) never returned data", rd_q.size()));

    // The hardware counters must agree with what the scoreboard counted
    if (sbe_count !== n_sbe) error("ECC_COUNT", $sformatf("sbe_count=%0d expected %0d", sbe_count, n_sbe));
    if (dbe_count !== n_dbe) error("ECC_COUNT", $sformatf("dbe_count=%0d expected %0d", dbe_count, n_dbe));
    n_errors += u_chk.total_fails();

    $display("--------------------------------------------");
    $display(" test=%s writes=%0d reads=%0d", test_name, n_wr, n_rd);
    $display(" clean=%0d single-bit corrected=%0d double-bit detected=%0d", n_clean, n_sbe, n_dbe);
    $display(" hardware counters: sbe=%0d dbe=%0d", sbe_count, dbe_count);
    u_chk.summary();
    $display(" errors=%0d", n_errors);
    $display(" %s", (n_errors == 0) ? "TEST PASSED" : "TEST FAILED");
    $display("--------------------------------------------");
    $finish;
  end

  initial begin
    #5_000_000_000;   // 5 ms
    $display("TIMEOUT: test did not finish");
    $display(" TEST FAILED");
    $finish;
  end
endmodule
