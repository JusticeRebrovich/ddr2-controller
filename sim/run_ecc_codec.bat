@echo off
REM run_ecc_codec.bat -- exhaustive single/double-error check of the SECDED code (no DRAM model needed).
setlocal
cd /d "%~dp0"
set VIV=C:\Xilinx\Vivado\2020.2\bin
call "%VIV%\xvlog.bat" -sv %DEFS% ..\ddr2_ecc.sv ..\tb_ecc_codec.sv || goto :fail
call "%VIV%\xelab.bat" -debug typical -timescale 1ps/1ps tb_ecc_codec -s codec_sim || goto :fail
call "%VIV%\xsim.bat" codec_sim -runall -log ecc_codec.log
exit /b %errorlevel%
:fail
echo *** BUILD FAILED ***
exit /b 1
