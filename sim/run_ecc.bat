@echo off
REM run_ecc.bat -- ECC controller + Micron model with error injection (see tb_ecc.sv).
REM   sim\run_ecc.bat            all ECC tests
REM   sim\run_ecc.bat single     one test: clean | single | double | random
setlocal
cd /d "%~dp0"
set VIV=C:\Xilinx\Vivado\2020.2\bin
set SRC=..
set DEFS=-d sg25E -d x16
set TST=%1
if "%TST%"=="" set TST=all
call "%VIV%\xvlog.bat" -sv %DEFS% %EXTRA% -i %SRC% ^
  %SRC%\ddr2_pkg.sv %SRC%\ddr2_ecc.sv %SRC%\ddr2_init.sv %SRC%\ddr2_ctrl.sv ^
  %SRC%\ddr2_phy.sv %SRC%\ddr2_top.sv %SRC%\ddr2_timing_checker.sv %SRC%\tb_ecc.sv || goto :fail
call "%VIV%\xvlog.bat" %DEFS% -i %SRC% %SRC%\ddr2.v || goto :fail
call "%VIV%\xelab.bat" -debug typical -timescale 1ps/1ps tb_ecc -s ecc_sim || goto :fail
call "%VIV%\xsim.bat" ecc_sim -runall -log ecc.log -testplusarg "TEST=%TST%"
exit /b %errorlevel%
:fail
echo *** BUILD FAILED ***
exit /b 1
