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
  RubyInstaller DevKit (MSYS2). Bundler resolves compatible Windows binaries
  for sqlite3 and tiktoken_ruby.

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
    ridk install 1 3

Or re-run this script with -InstallRuby to attempt the winget install.
"@ -ForegroundColor Yellow
    exit 1
}
Write-Step "Ruby: $ruby"

$rubyBin   = Split-Path -Parent $ruby
# Use Ruby scripts directly: RubyInstaller releases use both .cmd and .bat
# wrappers. Keep every subprocess on the selected Ruby, including native builds.
$env:PATH = "$rubyBin;$env:PATH"
$env:RUBY = $ruby
$gemScript = Join-Path $rubyBin 'gem'
if (-not (Test-Path -LiteralPath $gemScript -PathType Leaf)) {
    throw "RubyGems is missing from $rubyBin. Install Ruby with RubyGems included."
}
$bundleRunner = "load Gem.bin_path('bundler', 'bundle', '2.3.27')"

# ----------------------------------------------------------------- version check
$ver = & $ruby -e "print RUBY_VERSION"
if ($LASTEXITCODE -ne 0 -or [version]$ver -lt [version]'3.1.0') {
    Write-Host "[aetheroracle] Ruby $ver is too old; need >= 3.1." -ForegroundColor Red
    exit 1
}
Write-Step "Ruby $ver"

# ------------------------------------------------------------------ DevKit check
$ridk = @('ridk.cmd', 'ridk.bat', 'ridk.ps1') |
    ForEach-Object { Join-Path $rubyBin $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $ridk) {
    throw "RubyInstaller DevKit (ridk) not found in $rubyBin. Install Ruby + DevKit, then run ridk install 1 3."
}
# A ridk wrapper alone does not mean MSYS2 and its compiler are installed.
& $ruby -r ruby_installer/runtime -e "RubyInstaller::Runtime.msys2_installation.enable_msys_apps; exit(system('gcc', '--version', out: File::NULL) && system('make', '--version', out: File::NULL) ? 0 : 1)"
if ($LASTEXITCODE -ne 0) {
    throw "MSYS2 development tools are unavailable. Run: & '$ridk' install 1 3, then rerun setup."
}

# ---------------------------------------------------------------------- bundler
Write-Step "Ensuring bundler"
& $ruby $gemScript install bundler -v 2.3.27 --no-document
if ($LASTEXITCODE -ne 0) { throw "gem install bundler failed" }

# ----------------------------------------------------------------------- bundle
Write-Step "Configuring bundle (local path = ruby/.vendor_bundle)"
Push-Location $rubyDir
try {
    & $ruby -r rubygems -e $bundleRunner -- config set --local path .vendor_bundle
    if ($LASTEXITCODE -ne 0) { throw "bundle config failed" }

    & $ruby -r rubygems -e $bundleRunner -- lock --add-platform x64-mingw-ucrt
    if ($LASTEXITCODE -ne 0) { throw "bundle lock failed" }

    & $ruby -r rubygems -e $bundleRunner -- install
    if ($LASTEXITCODE -ne 0) { throw "bundle install failed" }
} finally {
    Pop-Location
}

# -------------------------------------------------------------------- smoke test
if (-not $SkipSmokeTest) {
    Write-Step "Smoke test"
    $aether = Join-Path $repo 'bin\aetheroracle.cmd'
    & $aether peers
    if ($LASTEXITCODE -ne 0) { throw "CLI peers smoke test failed" }
    Write-Host ""
    & $aether config
    if ($LASTEXITCODE -ne 0) { throw "CLI config smoke test failed" }
}

Write-Host ""
Write-Host "[aetheroracle] Windows full-control ready." -ForegroundColor Green
Write-Host "  Link tier : aetheroracle.cmd peers / invoke <peer> \"prompt\""
Write-Host "  Brain tier: aetheroracle.cmd ask \"prompt\" / server / config / task"
