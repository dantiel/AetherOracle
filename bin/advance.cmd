@echo off
rem =============================================================
rem advance.cmd - commit-advance-all release tool (pure stdlib,
rem LINK tier: runs with any Ruby, no gems, no bundle).
rem
rem Ruby resolution order: ruby/.portable -> %RUBY% -> PATH.
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
    echo [advance] Ruby not found.
    exit /b 1
)

"%RUBY_EXE%" "%~dp0advance" %*
exit /b %ERRORLEVEL%
