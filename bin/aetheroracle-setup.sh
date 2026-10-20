#!/bin/sh
# =============================================================
# AetherOracle - one-command install for macOS/Linux. Provisions the
# aetheroracle RubyGem, installs it (7 aliases + full brain), and
# smoke-tests the CLI.
#
#   bin/aetheroracle-setup.sh                 # use existing Ruby
#   bin/aetheroracle-setup.sh --install-ruby  # brew install ruby (best-effort)
#   bin/aetheroracle-setup.sh --skip-smoke-test
#
# Installing turns the machine into an Aether OS: the oracle is reachable
# under seven names - aetheroracle, aether, oracle, oracleaether, ae, aero,
# orae - all the same aether in the CLI.
#
# The gem install pulls the full brain tier (ask / server / config / task /
# repl) and its dependencies. The native gems (sqlite3, tiktoken_ruby) ship
# precompiled binaries for x86_64-darwin / arm64-darwin / linux at the pinned
# ranges, so no Rust is required; only the three C gems (redcarpet /
# eventmachine / websocket-driver) need the Xcode Command Line Tools.
#
# The link tier (peers / heartbeat / invoke) is pure stdlib and works with
# any Ruby even before the brain gems are installed.
# =============================================================

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GEMSPEC="$REPO/aetheroracle.gemspec"
PORTABLE="$REPO/ruby/.portable/bin/ruby"

INSTALL_RUBY=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --install-ruby|-i) INSTALL_RUBY=1 ;;
    --skip-smoke-test|-s) SKIP_SMOKE=1 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

find_ruby() {
  if [ -x "$PORTABLE" ]; then
    printf '%s\n' "$PORTABLE"
    return 0
  fi
  if [ -n "$RUBY" ] && [ -x "$RUBY" ]; then
    printf '%s\n' "$RUBY"
    return 0
  fi
  command -v ruby 2>/dev/null || true
}

if [ "$INSTALL_RUBY" -eq 1 ]; then
  step "Installing Ruby via Homebrew (best-effort)"
  if command -v brew >/dev/null 2>&1; then
    brew install ruby || echo "brew install ruby failed" >&2
  else
    echo "Homebrew not found. Install it from https://brew.sh, or install Ruby (>= 3.1) yourself." >&2
  fi
fi

RUBY_EXE=$(find_ruby)
if [ -z "$RUBY_EXE" ]; then
  cat >&2 <<'EOF'

[aetheroracle] Ruby (>= 3.1) not found.

One-time install (recommended):
    brew install ruby

Or re-run this script with --install-ruby to attempt the brew install.
EOF
  exit 1
fi
step "Ruby: $RUBY_EXE"

RUBY_BIN=$(dirname "$RUBY_EXE")
PATH="$RUBY_BIN:$PATH"
export PATH
export RUBY="$RUBY_EXE"

# version check
VER=$("$RUBY_EXE" -e 'print RUBY_VERSION')
MAJOR=$(printf '%s' "$VER" | cut -d. -f1)
MINOR=$(printf '%s' "$VER" | cut -d. -f2)
if [ "$MAJOR" -lt 3 ] || { [ "$MAJOR" -eq 3 ] && [ "$MINOR" -lt 1 ]; }; then
  echo "[aetheroracle] Ruby $VER is too old; need >= 3.1." >&2
  exit 1
fi
step "Ruby $VER"

# compiler check (C gems: redcarpet / eventmachine / websocket-driver)
if ! command -v cc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
  echo "[aetheroracle] No C compiler found. The three C gems (redcarpet, eventmachine, websocket-driver) will fail to build." >&2
  echo "Install the Xcode Command Line Tools once:  xcode-select --install" >&2
fi

# ---------------------------------------------------------- build + install
step "Building the aetheroracle gem"
if [ ! -f "$GEMSPEC" ]; then
  echo "aetheroracle.gemspec not found in $REPO" >&2
  exit 1
fi

( cd "$REPO" && gem build aetheroracle.gemspec )
BUILT=$(ls -t "$REPO"/aetheroracle-*.gem 2>/dev/null | head -n 1)
if [ -z "$BUILT" ]; then
  echo "no aetheroracle-*.gem produced" >&2
  exit 1
fi

step "Installing $(basename "$BUILT") (pulls the brain tier + 7 aliases)"
gem install "$BUILT" --no-document

if [ "$SKIP_SMOKE" -eq 0 ]; then
  step "Smoke test"
  aetheroracle peers || true
  printf '\n'
  aetheroracle config || true
fi

printf '\n'
echo "[aetheroracle] Aether OS ready."
echo "  Seven names, one oracle: aetheroracle · aether · oracle · oracleaether · ae · aero · orae"
echo "  Link tier : aether peers / invoke <peer> \"prompt\""
echo "  Brain tier: aether ask \"prompt\" / server / config / task"
