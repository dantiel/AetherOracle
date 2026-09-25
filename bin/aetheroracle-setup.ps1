#Requires -Version 5.1
<#
.SYNOPSIS
  AetherOracle - Windows full-control bootstrap.
  Provisions the gems + platform lock so the *brain tier* of the aetheroracle
  CLI runs locally on Windows (ask / server / config / task / repl).

.DESCRIPTION
  The link tier (peers / heartbeat / invoke) is pure stdlib and already runs on
  Windows with any Ruby. This script provisions the rest:

    1. Locate Ruby (>= 3.1): portable -> RUBY env -> PATH.
    2. Ensure bundler, pin the local gem path to ruby/.vendor_bundle, add the
       x64-mingw-ucrt platform, and bundle install.
    3. Smoke-test the CLI (peers + config).

  The native gems with no precompiled Windows binary in this profile
  (redcarpet / eventmachine / websocket-driver) compile automatically via the
  RubyInstaller DevKit (MSYS2). No Rust is required: sqlite3 1.7.3 and
  tiktoken_ruby 0.0.9 ship precompiled x64-mingw-ucrt gems for the exact
  pinned versions.

.PARAMETER InstallRuby
  Attempt a non-interactive RubyInstaller (Ruby + DevKit) install via winget.
.PARAMETER SkipSmokeTest
  Skip the post-install CLI smoke test.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File bin\aetheroracle-setup.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File bin\aetheroracle-setup.ps1 -InstallRuby
#>
[CmdletBinding()]
param(
    [switch]$InstallRuby,
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'
$repo     = Split-Path -Parent $PSScriptRoot
$rubyDir  = Join-Path $repo 'ruby'
$portable = Join-Path $rubyDir '.portable\bin\ruby.exe'

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# ------------------------------------------------------------------ locate ruby
function Get-RubyExe {
    if (Test-Path $portable) { return $portable }
    if ($env:RUBY -and (Test-Path $env:RUBY)) { return $env:RUBY }
    $cmd = Get-Command ruby.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

if ($InstallRuby) {
    Write-Step "Installing Ruby + DevKit via winget (best-effort)"
    try {
        winget install --id RubyInstallerTeam.RubyWithDevKit.3.1 -e `
            --accept-package-agreements --accept-source-agreements --silent
    } catch {
        Write-Host "winget install failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$ruby = Get-RubyExe
if (-not $ruby) {
    Write-Host @"

[aetheroracle] Ruby (>= 3.1) not found.

One-time install (recommended: Ruby + DevKit):
    winget install --id RubyInstallerTeam.RubyWithDevKit.3.1 -e

Then complete the MSYS2 toolchain (needed to compile redcarpet / eventmachine /
websocket-driver):
    ridk install 2 3

Or re-run this script with -InstallRuby to attempt the winget install.
"@ -ForegroundColor Yellow
    exit 1
}
Write-Step "Ruby: $ruby"

$rubyBin   = Split-Path -Parent $ruby
$gemExe    = Join-Path $rubyBin 'gem.bat'
$bundleExe = Join-Path $rubyBin 'bundle.bat'

# ----------------------------------------------------------------- version check
$ver = & $ruby -e "print RUBY_VERSION"
if ($LASTEXITCODE -ne 0 -or [version]$ver -lt [version]'3.1.0') {
    Write-Host "[aetheroracle] Ruby $ver is too old; need >= 3.1." -ForegroundColor Red
    exit 1
}
Write-Step "Ruby $ver"

# ------------------------------------------------------------------ DevKit check
$ridk = Get-Command ridk.bat -ErrorAction SilentlyContinue
if (-not $ridk) {
    Write-Host "[aetheroracle] DevKit (ridk) not found. Native gems (redcarpet, eventmachine, websocket-driver) will fail to build." -ForegroundColor Yellow
    Write-Host "Run once:  ridk install 2 3" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------- bundler
Write-Step "Ensuring bundler"
& $gemExe install bundler -v 2.3.27 --no-document
if ($LASTEXITCODE -ne 0) { throw "gem install bundler failed" }

# ----------------------------------------------------------------------- bundle
Write-Step "Configuring bundle (local path = ruby/.vendor_bundle)"
Push-Location $rubyDir
try {
    & $bundleExe config set --local path .vendor_bundle
    if ($LASTEXITCODE -ne 0) { throw "bundle config failed" }

    & $bundleExe lock --add-platform x64-mingw-ucrt
    if ($LASTEXITCODE -ne 0) { throw "bundle lock failed" }

    & $bundleExe install
    if ($LASTEXITCODE -ne 0) { throw "bundle install failed" }
} finally {
    Pop-Location
}

# -------------------------------------------------------------------- smoke test
if (-not $SkipSmokeTest) {
    Write-Step "Smoke test"
    $aether = Join-Path $repo 'bin\aetheroracle.cmd'
    & $aether peers
    Write-Host ""
    & $aether config
}

Write-Host ""
Write-Host "[aetheroracle] Windows full-control ready." -ForegroundColor Green
Write-Host "  Link tier : aetheroracle.cmd peers / invoke <peer> \"prompt\""
Write-Host "  Brain tier: aetheroracle.cmd ask \"prompt\" / server / config / task"
