@echo off
rem Starts EObserver from a release on Windows, e.g.
rem   bin\eobs.cmd --node app@host --cookie secret
rem See bin/eobs for why the relx start script is bypassed.
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
for /f "usebackq tokens=1,2" %%A in ("%ROOT%\releases\start_erl.data") do (
  set "ERTS_VSN=%%A"
  set "REL_VSN=%%B"
)
set "REL_DIR=%ROOT%\releases\%REL_VSN%"
set "ERTS_BIN=%ROOT%\erts-%ERTS_VSN%\bin"

rem Without an erl.ini next to it, erl.exe takes its own directory as the
rem bin dir and two levels up as the root, which is right wherever the
rem release was unpacked or installed. A stale erl.ini (written for the
rem build machine) would point elsewhere, so the release ships without one;
rem remove any left over from an older copy.
if exist "%ERTS_BIN%\erl.ini" del /f /q "%ERTS_BIN%\erl.ini" >nul 2>&1

"%ERTS_BIN%\erl.exe" -boot "%REL_DIR%\start" -boot_var SYSTEM_LIB_DIR "%ROOT%\lib" ^
  -config "%REL_DIR%\sys.config" -args_file "%REL_DIR%\vm.args" -noshell -eobs_cli -extra %*
