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

rem erl.exe finds its installation through erl.ini next to it; the release
rem may have been moved since it was built, so rewrite it on every start.
set "INI_BIN=%ERTS_BIN:\=\\%"
set "INI_ROOT=%ROOT:\=\\%"
(
  echo [erlang]
  echo Bindir=%INI_BIN%
  echo Progname=erl
  echo Rootdir=%INI_ROOT%
) > "%ERTS_BIN%\erl.ini" 2>nul

"%ERTS_BIN%\erl.exe" -boot "%REL_DIR%\start" -boot_var SYSTEM_LIB_DIR "%ROOT%\lib" ^
  -config "%REL_DIR%\sys.config" -args_file "%REL_DIR%\vm.args" -noshell -eobs_cli -extra %*
