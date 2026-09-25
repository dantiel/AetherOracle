#Requires -Version 5.1
<#
.SYNOPSIS
  AetherOracle - one-command install. On Windows this provisions Ruby + DevKit,
  builds the aetheroracle RubyGem, installs it (7 aliases + full brain), and
  smoke-tests the CLI.

.DESCRIPTION
  Installing AetherOracle turns the machine into an Aether OS: the oracle is
  reachable under seven names — aetheroracle, aether, oracle, oracleaether,
  ae, aero, orae — all the same aether in the CLI.

  The gem install pulls the full brain tier (ask / server / config / task /
  repl) and its dependencies. The native gems (sqlite3 1.7.3, tiktoken_ruby
  0.0.17) ship precompiled x64-mingw-ucrt binaries, so no Rust is required;
  only the three C gems (redcarpet / eventmachine / websocket-driver) need the
  DevKit MSYS2 toolchain.

  The link tier (peers / heartbeat / invoke) is pure stdlib and works with any
  Ruby even before the brain gems are installed.

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
$gemspec  = Join-Path $repo 'aetheroracle.gemspec'
$portable = Join-Path $repo 'ruby\.portable\bin\ruby.exe'

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

Then complete the MSYS2 toolchain (needed only to compile redcarpet /
eventmachine / websocket-driver):
    ridk install 1 3

Or re-run this script with -InstallRuby to attempt the winget install.
"@ -ForegroundColor Yellow
    exit 1
}
Write-Step "Ruby: $ruby"

$rubyBin = Split-Path -Parent $ruby
# Use the selected Ruby for every subprocess (native builds included).
# RubyInstaller ships both .cmd and .bat wrappers; resolve either.
$env:PATH = "$rubyBin;$env:PATH"
$env:RUBY = $ruby

$gemExe = Join-Path $rubyBin 'gem.cmd'
if (-not (Test-Path -LiteralPath $gemExe -PathType Leaf)) {
    $gemExe = Join-Path $rubyBin 'gem.bat'
}
if (-not (Test-Path -LiteralPath $gemExe -PathType Leaf)) {
    throw "RubyGems is missing from $rubyBin. Install Ruby with RubyGems included."
}

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
    Write-Host "[aetheroracle] DevKit (ridk) not found. The three C gems (redcarpet, eventmachine, websocket-driver) will fail to build." -ForegroundColor Yellow
    Write-Host "Run once:  ridk install 1 3" -ForegroundColor Yellow
}

# -------------------------------------------------------------- build + install
Write-Step "Building the aetheroracle gem"
Push-Location $repo
try {
    if (-not (Test-Path $gemspec)) {
        throw "aetheroracle.gemspec not found in $repo"
    }

    & $gemExe build aetheroracle.gemspec
    if ($LASTEXITCODE -ne 0) { throw "gem build failed" }

    $built = Get-ChildItem -Path $repo -Filter 'aetheroracle-*.gem' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $built) { throw "no aetheroracle-*.gem produced" }

    Write-Step "Installing $($built.Name) (pulls the brain tier + 7 aliases)"
    & $gemExe install $built.FullName --no-document
    if ($LASTEXITCODE -ne 0) { throw "gem install failed" }
} finally {
    Pop-Location
}

# -------------------------------------------------------------------- smoke test
if (-not $SkipSmokeTest) {
    Write-Step "Smoke test"
    aetheroracle peers
    Write-Host ""
    aetheroracle config
}

Write-Host ""
Write-Host "[aetheroracle] Aether OS ready." -ForegroundColor Green
Write-Host "  Seven names, one oracle: aetheroracle · aether · oracle · oracleaether · ae · aero · orae"
Write-Host "  Link tier : aether peers / invoke <peer> `"prompt`""
Write-Host "  Brain tier: aether ask `"prompt`" / server / config / task"
