`timescale 1ps/1ps
// tb_top.sv
// Testbench: controller + Micron DDR2 model. Simulation source only.
//
// Structure (the same split a UVM testbench uses, without the library):
//   stimulus   - write()/read() tasks drive the user port; run_*() are the tests
//   scoreboard - shadow[] holds what memory should contain; rd_q holds the
//                expected data for every read issued but not yet returned
//   monitor    - watches rd_valid and checks each returned burst against rd_q
//
// Plusargs:
//   +TEST=directed|random|stress   which test to run (default directed)
//   +SEED=<n>                      label only; pass the real seed with xsim -sv_seed <n>
//   +N_OPS=<n>                     operations for random/stress (default 200)
//
// Every check prints "ERROR [<ID>] ..." so the regression script can find and
// group failures. The run always ends with TEST PASSED or TEST FAILED.
//
// Needs the defines sg25E and x16 for Micron's model, which also checks every
// DDR2 timing rule and prints its own ERROR lines.

module tb_top;
  import ddr2_pkg::*;

  // ---------------- Clocks and reset ----------------
  localparam int TCK = 2500;   // ps, DDR2-800

  logic clk   = 1'b0;
  logic clk90 = 1'b0;
  logic rst_n = 1'b0;

  always #(TCK/2) clk = ~clk;
  initial begin
    #(TCK/4);                          // quarter-period delay
    forever #(TCK/2) clk90 = ~clk90;
  end

  initial begin
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------- DUT <-> memory wires ----------------
  logic                  req_valid = 1'b0;
  logic                  req_ready;
  logic                  req_we    = 1'b0;
  logic [UADDR_BITS-1:0] req_addr  = '0;
  logic [BURST_BITS-1:0] req_wdata = '0;
  logic                  rd_valid;
  logic [BURST_BITS-1:0] rd_data;
  logic                  init_done;

  wire                   ck, ck_n, cke, cs_n, ras_n, cas_n, we_n, odt;
  wire [BA_BITS-1:0]     ba;
  wire [ADDR_BITS-1:0]   addr;
  wire [DM_BITS-1:0]     dm_rdqs;
  wire [DQ_BITS-1:0]     dq;
  wire [DQS_BITS-1:0]    dqs, dqs_n;
  wire [DQS_BITS-1:0]    rdqs_n;

  ddr2_top u_dut (
    .clk      (clk),
    .clk90    (clk90),
    .rst_n    (rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_we   (req_we),
    .req_addr (req_addr),
    .req_wdata(req_wdata),
    .rd_valid (rd_valid),
    .rd_data  (rd_data),
    .init_done(init_done),
    .ck       (ck),
    .ck_n     (ck_n),
    .cke      (cke),
    .cs_n     (cs_n),
    .ras_n    (ras_n),
    .cas_n    (cas_n),
    .we_n     (we_n),
    .odt      (odt),
    .ba       (ba),
    .addr     (addr),
    .dm_rdqs  (dm_rdqs),
    .dq       (dq),
    .dqs      (dqs),
    .dqs_n    (dqs_n)
  );

  // Micron's model
  ddr2 u_mem (
    .ck      (ck),
    .ck_n    (ck_n),
    .cke     (cke),
    .cs_n    (cs_n),
    .ras_n   (ras_n),
    .cas_n   (cas_n),
    .we_n    (we_n),
    .dm_rdqs (dm_rdqs),
    .ba      (ba),
    .addr    (addr),
    .dq      (dq),
    .dqs     (dqs),
    .dqs_n   (dqs_n),
    .rdqs_n  (rdqs_n),
    .odt     (odt)
  );

  // SVA timing checker: watches the command pins between controller and memory.
  // Armed once initialization is done. Its failures print "ERROR [SVA_*]".
  ddr2_timing_checker u_chk (
    .ck(ck), .enable(init_done),
    .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .addr(addr)
  );

  // ---------------- Config and error reporting ----------------
  string test_name = "directed";
  int    seed      = 1;
  int    n_ops     = 200;
  int    n_errors  = 0;

  function automatic void error(string id, string msg);
    n_errors++;
    $display("[%0t] ERROR [%s] %s", $time, id, msg);
  endfunction

  function automatic string fmt(logic [UADDR_BITS-1:0] a);
    return $sformatf("row=%0d bank=%0d col=%0d",
                     a[COL_BITS+BA_BITS +: ROW_BITS], a[COL_BITS +: BA_BITS], a[COL_BITS-1:0]);
  endfunction

  function automatic logic [UADDR_BITS-1:0] mkaddr(int row, int bank, int col);
    return {ROW_BITS'(row), BA_BITS'(bank), COL_BITS'(col & ~7)};
  endfunction

  // ---------------- Scoreboard ----------------
  typedef struct {
    logic [UADDR_BITS-1:0] addr;
    logic [BURST_BITS-1:0] data;
  } exp_t;

  logic [BURST_BITS-1:0] shadow [logic [UADDR_BITS-1:0]];  // what DRAM should hold
  exp_t                  rd_q   [$];                       // reads waiting for data
  int n_wr = 0, n_rd = 0, n_checked = 0;

  // ---------------- Monitor: check every returned burst ----------------
  always @(negedge clk) if (rst_n && rd_valid) begin
    exp_t e;
    if (rd_q.size() == 0) begin
      error("SCB", $sformatf("read data %h returned with no read outstanding", rd_data));
    end else begin
      e = rd_q.pop_front();
      n_checked++;
      if (rd_data !== e.data)
        error("SCB", $sformatf("data mismatch %s exp=%h got=%h", fmt(e.addr), e.data, rd_data));
    end
  end

  // ---------------- Stimulus ----------------
  // Hold a request until the controller accepts it. The testbench drives and
  // samples on negedge, half a cycle away from the DUT's posedge, so there's
  // no race over who sees which value first.
  task automatic send(input logic we, input logic [UADDR_BITS-1:0] a,
                      input logic [BURST_BITS-1:0] d);
    @(negedge clk);
    req_valid = 1'b1;
    req_we    = we;
    req_addr  = a;
    req_wdata = d;
    while (!req_ready) @(negedge clk);   // ready is stable mid-cycle
    @(posedge clk);                       // controller accepts on this edge
    @(negedge clk);
    req_valid = 1'b0;
  endtask

  task automatic write(input logic [UADDR_BITS-1:0] a, input logic [BURST_BITS-1:0] d);
    send(1'b1, a, d);
    shadow[a] = d;
    n_wr++;
  endtask

  // Non-blocking read: queue the expected data and move on; the monitor checks it.
  task automatic read(input logic [UADDR_BITS-1:0] a);
    if (!shadow.exists(a)) begin
      error("TB", $sformatf("test read %s before writing it", fmt(a)));
      return;
    end
    send(1'b0, a, '0);
    rd_q.push_back('{addr: a, data: shadow[a]});
    n_rd++;
  endtask

  function automatic logic [BURST_BITS-1:0] rand_data();
    return {$urandom, $urandom, $urandom, $urandom};
  endfunction

  // ---------------- Tests ----------------
  // directed: the original hand-written sequence
  task automatic run_directed();
    logic [UADDR_BITS-1:0] a0, a1, a2, a3;
    a0 = mkaddr(0,     0, 0);
    a1 = mkaddr(5,     2, 8);
    a2 = mkaddr(1234,  5, 512);
    a3 = mkaddr(16383, 7, 1016);   // last row, last bank, last burst in the row

    write(a0, 128'h0F0E0D0C_0B0A0908_07060504_03020100);
    write(a1, 128'h77776666_55554444_33332222_11110000);
    write(a2, 128'hDEADBEEF_CAFEF00D_12345678_9ABCDEF0);
    write(a3, 128'hFFFF0000_AAAA5555_0000FFFF_5555AAAA);
    read(a0); read(a1); read(a2); read(a3);

    write(a1, 128'h01234567_89ABCDEF_FEDCBA98_76543210);   // overwrite, read straight back
    read(a1);

    #20_000_000;                   // idle across several tREFI so refresh runs
    read(a0); read(a1); read(a2); read(a3);
  endtask

  // random: random mix of reads and writes over a small, clustered address
  // pool (2 rows x 8 banks x 8 bursts) so the same rows and banks get hit
  // repeatedly, with random idle gaps. max_gap = 0 means fully back-to-back.
  task automatic run_random(int n, bit back_to_back);
    logic [UADDR_BITS-1:0] pool [24];
    int rows [2];
    int gap;
    rows[0] = $urandom_range(0, 2**ROW_BITS-1);
    rows[1] = $urandom_range(0, 2**ROW_BITS-1);
    foreach (pool[i])
      pool[i] = mkaddr(rows[$urandom_range(0,1)], $urandom_range(0, 7), 8*$urandom_range(0, 7));

    for (int i = 0; i < n; i++) begin
      logic [UADDR_BITS-1:0] a;
      a = pool[$urandom_range(0, $size(pool)-1)];
      // Read only what's been written; otherwise 50/50 read or write
      if (shadow.exists(a) && $urandom_range(0, 1)) read(a);
      else                                          write(a, rand_data());

      if (!back_to_back) begin
        // 60% no gap, 30% short gap, 10% long idle so refresh can land in idle too
        case ($urandom_range(0, 9))
          0,1,2,3,4,5: gap = 0;
          6,7,8:       gap = $urandom_range(1, 20);
          default:     gap = $urandom_range(200, 1500);
        endcase
        repeat (gap) @(negedge clk);
      end
    end
  endtask

  // ---------------- Functional coverage (simple counters) ----------------
  // Real projects use covergroups. These counters answer the same question:
  // did the test actually exercise the interesting cases?
  int n_ref = 0, n_ref_while_waiting = 0;
  int bank_hits [8];
  always @(posedge ck) if (init_done && cke) begin
    if ({cs_n, ras_n, cas_n, we_n} == CMD_REF) begin
      n_ref++;
      if (req_valid) n_ref_while_waiting++;   // refresh won against a waiting request
    end
    if ({cs_n, ras_n, cas_n, we_n} == CMD_ACT) bank_hits[ba]++;
  end

  // ---------------- Main ----------------
  initial begin
    bit found;   // 1 if the plusarg was given; otherwise the default stays
    found = $value$plusargs("TEST=%s",  test_name);
    found = $value$plusargs("SEED=%d",  seed);
    found = $value$plusargs("N_OPS=%d", n_ops);
    // The random seed itself comes from the simulator (xsim -sv_seed <n>);
    // +SEED only records it in the log. xsim 2020.2 can't seed via $urandom(seed).
    $display("[%0t] test=%s seed=%0d n_ops=%0d", $time, test_name, seed, n_ops);

    wait (init_done);
    $display("[%0t] init_done", $time);
    @(posedge clk);

    case (test_name)
      "directed": run_directed();
      "random":   run_random(n_ops, 1'b0);
      "stress":   run_random(n_ops, 1'b1);
      default:    error("TB", $sformatf("unknown test '%s'", test_name));
    endcase

    // Drain: every read issued must come back
    fork
      wait (rd_q.size() == 0);
      repeat (1000) @(posedge clk);
    join_any
    disable fork;
    if (rd_q.size() != 0)
      error("SCB", $sformatf("%0d read(s) never returned data", rd_q.size()));

    n_errors += u_chk.total_fails();
    begin
      int banks = 0;
      foreach (bank_hits[b]) if (bank_hits[b] > 0) banks++;
      $display("--------------------------------------------");
      $display(" test=%s seed=%0d", test_name, seed);
      $display(" writes=%0d reads=%0d checked=%0d errors=%0d", n_wr, n_rd, n_checked, n_errors);
      $display(" coverage: refreshes=%0d refresh_while_request_waiting=%0d banks_hit=%0d/8",
               n_ref, n_ref_while_waiting, banks);
      u_chk.summary();
      $display(" %s", (n_errors == 0) ? "TEST PASSED" : "TEST FAILED");
      $display("--------------------------------------------");
    end
    $finish;
  end

  // Watchdog so a hang doesn't run forever
  initial begin
    #2_000_000_000;   // 2 ms
    $display("TIMEOUT: test did not finish");
    $display(" TEST FAILED");
    $finish;
  end

endmodule
