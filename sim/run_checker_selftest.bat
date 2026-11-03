@echo off
REM run_checker_selftest.bat -- tests the SVA timing checker against deliberately illegal command streams.
setlocal
cd /d "%~dp0"
set VIV=C:\Xilinx\Vivado\2020.2\bin
call "%VIV%\xvlog.bat" -sv ..\ddr2_pkg.sv ..\ddr2_timing_checker.sv ..\tb_checker_selftest.sv || goto :fail
call "%VIV%\xelab.bat" -debug typical -timescale 1ps/1ps tb_checker_selftest -s chk_sim || goto :fail
call "%VIV%\xsim.bat" chk_sim -runall -log chk_selftest.log
exit /b %errorlevel%
:fail
echo *** BUILD FAILED ***
exit /b 1
