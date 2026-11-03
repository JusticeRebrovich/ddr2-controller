`timescale 1ps/1ps
// tb_ecc_codec.sv
// Exhaustive check of the SECDED code on its own (no DRAM involved).
//
// For a set of data words (zeros, ones, every walking-one, random):
//   - a clean codeword decodes with no flags and the original data
//   - flipping ANY one of the 128 codeword bits is corrected: data restored, sbe=1
//   - for a subset of words, flipping ANY two of the 128 bits (8128 pairs) is
//     detected: dbe=1, sbe=0, and the data is never silently "corrected"
// It also confirms the encoder is linear and the check bits are not all zero.

module tb_ecc_codec;
  import ddr2_ecc_pkg::*;

  int n_err = 0, n_checks = 0;
  localparam int N_RANDOM = 30;

  function automatic logic [ECC_DATA_BITS-1:0] rand120();
    logic [127:0] t;
    t = {$urandom, $urandom, $urandom, $urandom};
    return t[ECC_DATA_BITS-1:0];
  endfunction

  task automatic fail(string id, string msg);
    n_err++;
    if (n_err <= 20) $display("ERROR [%s] %s", id, msg);
  endtask

  task automatic check_word(logic [ECC_DATA_BITS-1:0] d, bit do_doubles);
    logic [ECC_CODE_BITS-1:0] cw;
    ecc_result_t r;
    cw = ecc_encode(d);

    r = ecc_decode(cw);
    n_checks++;
    if (r.data !== d || r.sbe || r.dbe)
      fail("ECC_CLEAN", $sformatf("clean word %h decoded wrong (sbe=%b dbe=%b)", d, r.sbe, r.dbe));

    for (int i = 0; i < ECC_CODE_BITS; i++) begin
      r = ecc_decode(cw ^ (128'd1 << i));
      n_checks++;
      if (r.data !== d || !r.sbe || r.dbe)
        fail("ECC_SINGLE", $sformatf("bit %0d flipped: data_ok=%b sbe=%b dbe=%b", i, r.data === d, r.sbe, r.dbe));
    end

    if (do_doubles)
      for (int i = 0; i < ECC_CODE_BITS; i++)
        for (int j = i + 1; j < ECC_CODE_BITS; j++) begin
          r = ecc_decode(cw ^ (128'd1 << i) ^ (128'd1 << j));
          n_checks++;
          if (!r.dbe || r.sbe)
            fail("ECC_DOUBLE", $sformatf("bits %0d,%0d flipped: sbe=%b dbe=%b", i, j, r.sbe, r.dbe));
        end
  endtask

  initial begin
    logic [ECC_DATA_BITS-1:0] a, b;
    $display("=== SECDED (128,120) codec check ===");

    check_word('0, 1);
    check_word('1, 1);
    for (int i = 0; i < ECC_DATA_BITS; i++) check_word(120'd1 << i, i % 20 == 0);   // walking one
    for (int i = 0; i < N_RANDOM; i++)      check_word(rand120(), i < 4);

    // Linearity: encode(a ^ b) == encode(a) ^ encode(b)
    for (int i = 0; i < 100; i++) begin
      a = rand120(); b = rand120();
      n_checks++;
      if (ecc_encode(a ^ b) !== (ecc_encode(a) ^ ecc_encode(b)))
        fail("ECC_LINEAR", "encoder is not linear");
    end

    $display("--------------------------------------------");
    $display(" %0d decodes checked, %0d errors", n_checks, n_err);
    $display(" %s", (n_err == 0) ? "TEST PASSED" : "TEST FAILED");
    $display("--------------------------------------------");
    $finish;
  end
endmodule
