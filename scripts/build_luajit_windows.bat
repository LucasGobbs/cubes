@echo off
rem UNVERIFIED on Windows: written from reading msvcbuild.bat only; never executed on Windows.
rem Builds third_party\luajit\src\lua51.lib (static, GC64) with the /MD CRT (plan.md section 9).
rem Run from the repo root in an x64 Native Tools / VS x64 developer prompt. Called by `make luajit` on Windows.
setlocal

call :CHECK_CL
if errorlevel 1 exit /b 1

rem msvcbuild.bat static compiles lj_*.c without its /MD flag; CL makes every cl call use /MD.
set CL=/MD

rem Drop any stale lib so the existence check below reflects this build only.
del "third_party\luajit\src\lua51.lib" 2>nul

pushd third_party\luajit\src
rem `call` is required: msvcbuild.bat exits the whole script otherwise. Its failure paths
rem do not set errorlevel, so success is judged by lua51.lib existing below.
call msvcbuild.bat static gc64
popd

if not exist "third_party\luajit\src\lua51.lib" (
  echo ERROR: third_party\luajit\src\lua51.lib was not produced. Check the msvcbuild.bat output above.
  exit /b 1
)

echo Built third_party\luajit\src\lua51.lib
echo Verify the CRT: it must list MSVCRT, not LIBCMT:
echo   dumpbin /directives third_party\luajit\src\lua51.lib ^| findstr DEFAULTLIB
exit /b 0

:CHECK_CL
where cl >nul 2>&1
if errorlevel 1 (
  echo ERROR: cl.exe is not on PATH. Open the x64 Native Tools Command Prompt for VS ^(or run vcvars64.bat^), then run this script from the repo root.
  exit /b 1
)
exit /b 0
