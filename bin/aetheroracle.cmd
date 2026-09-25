@echo off
rem =============================================================
rem AetherOracle CLI - Windows full-control launcher.
rem
rem   LINK tier  (peers / heartbeat / invoke): pure stdlib, runs
rem               with any Ruby - no gems, no bundle.
rem   BRAIN tier (ask / server / config / task / logs / repl):
rem               runs via `bundle exec` against ruby/.vendor_bundle.
rem
rem Ruby resolution order: ruby/.portable -> %RUBY% -> PATH.
rem Provision everything first with:
rem   powershell -ExecutionPolicy Bypass -File "%~dp0aetheroracle-setup.ps1"
rem =============================================================
setlocal

set "DIR=%~dp0"
set "RUBY_EXE="

rem 1) portable ruby (installed by aetheroracle-setup.ps1 -Portable workflows)
if exist "%DIR%..\ruby\.portable\bin\ruby.exe" set "RUBY_EXE=%DIR%..\ruby\.portable\bin\ruby.exe"

rem 2) %RUBY% env var
if not defined RUBY_EXE if defined RUBY set "RUBY_EXE=%RUBY%"

rem 3) PATH (resolve to full path)
if not defined RUBY_EXE for /f "delims=" %%R in ('where ruby.exe 2^>nul') do if not defined RUBY_EXE set "RUBY_EXE=%%R"

if not defined RUBY_EXE (
    echo [aetheroracle] Ruby not found. Run:
    echo   powershell -ExecutionPolicy Bypass -File "%~dp0aetheroracle-setup.ps1"
    exit /b 1
)

rem classify the command: brain tier needs bundler, link tier does not
set "CMD=%~1"
set "BRAIN=0"
for %%C in (ask server config task logs repl) do if /i "%CMD%"=="%%C" set "BRAIN=1"

if "%BRAIN%"=="1" goto :brain

rem ---- LINK tier: plain ruby, stdlib only ----
"%RUBY_EXE%" "%~dp0aetheroracle" %*
exit /b %ERRORLEVEL%

:brain
for %%I in ("%RUBY_EXE%") do set "RUBY_BIN=%%~dpI"
if not exist "%RUBY_BIN%bundle.bat" (
    echo [aetheroracle] bundler not installed. Run:
    echo   powershell -ExecutionPolicy Bypass -File "%~dp0aetheroracle-setup.ps1"
    exit /b 1
)
set "BUNDLE_GEMFILE=%DIR%..\ruby\Gemfile"
pushd "%DIR%..\ruby"
"%RUBY_BIN%bundle.bat" exec ruby "%DIR%..\ruby\cli.rb" %*
set "CODE=%ERRORLEVEL%"
popd
exit /b %CODE%
