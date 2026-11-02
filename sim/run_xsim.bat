@echo off
REM run_xsim.bat -- compile, elaborate and simulate tb_top with Vivado's xsim.
REM Run from anywhere: it cd's into this sim\ folder so all tool output stays here.
REM
REM   xvlog = compile (like vlog in ModelSim)
REM   xelab = elaborate: link modules into one snapshot (like vopt)
REM   xsim  = run the snapshot (like vsim)

setlocal
cd /d "%~dp0"
set VIV=C:\Xilinx\Vivado\2020.2\bin
set SRC=..

REM -d sets a `define (same as +define+ in ModelSim). -i adds an include dir.
set DEFS=-d sg25E -d x16

REM 1. Compile. Package first, because every other file imports ddr2_pkg.
call %VIV%\xvlog.bat -sv %DEFS% -i %SRC% ^
  %SRC%\ddr2_pkg.sv %SRC%\ddr2_init.sv %SRC%\ddr2_ctrl.sv ^
  %SRC%\ddr2_phy.sv %SRC%\ddr2_top.sv %SRC%\tb_top.sv || goto :fail
call %VIV%\xvlog.bat %DEFS% -i %SRC% %SRC%\ddr2.v || goto :fail

REM 2. Elaborate. -debug typical keeps signal visibility for waveforms.
call %VIV%\xelab.bat -debug typical -timescale 1ps/1ps tb_top -s tb_top_sim || goto :fail

REM 3. Simulate. Pass "gui" as an argument to open the waveform viewer instead.
if /i "%1"=="gui" (
  call %VIV%\xsim.bat tb_top_sim -gui -tclbatch wave.tcl
) else (
  call %VIV%\xsim.bat tb_top_sim -runall -log sim.log
)
exit /b %errorlevel%

:fail
echo *** BUILD FAILED ***
exit /b 1
