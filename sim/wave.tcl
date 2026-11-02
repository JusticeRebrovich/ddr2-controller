# wave.tcl -- default waveform layout for tb_top, loaded by xsim -gui -tclbatch.
# Each command is wrapped in catch so one bad signal path doesn't stop the rest.

proc w {args} { if {[catch {uplevel 1 add_wave $args} msg]} { puts "wave.tcl: $msg" } }
proc div {name} { catch {add_wave_divider $name} }

div "User side"
w /tb_top/clk
w /tb_top/init_done
w /tb_top/req_valid
w /tb_top/req_ready
w /tb_top/req_we
w -radix hex /tb_top/req_addr
w -radix hex /tb_top/req_wdata
w /tb_top/rd_valid
w -radix hex /tb_top/rd_data

div "Controller"
w /tb_top/u_dut/u_ctrl/state
w /tb_top/u_dut/u_ctrl/cmd
w -radix unsigned /tb_top/u_dut/u_ctrl/wait_cnt
w -radix unsigned /tb_top/u_dut/u_ctrl/tras_cnt
w /tb_top/u_dut/u_ctrl/ref_pending

div "DDR2 pins"
w /tb_top/ck
w /tb_top/cke
w /tb_top/cs_n
w /tb_top/ras_n
w /tb_top/cas_n
w /tb_top/we_n
w /tb_top/ba
w -radix hex /tb_top/addr
w /tb_top/dqs
w -radix hex /tb_top/dq

run all
