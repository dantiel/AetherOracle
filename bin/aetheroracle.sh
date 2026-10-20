#!/bin/sh
# =============================================================
# AetherOracle CLI - macOS/Linux full-control launcher (source-checkout).
#
#   LINK tier  (peers / heartbeat / invoke): pure stdlib, runs
#               with any Ruby - no gems, no bundle.
#   BRAIN tier (no args / ask / chamber / server / config / task / logs):
#               runs via bundler against ruby/Gemfile (ruby/.vendor_bundle).
#
# Ruby resolution order: ruby/.portable -> $RUBY -> PATH.
# Provision everything first with:
#   bin/aetheroracle-setup.sh
# =============================================================

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
RUBY_EXE=""

# 1) portable ruby (installed by aetheroracle-setup.sh workflows)
if [ -z "$RUBY_EXE" ] && [ -x "$DIR/../ruby/.portable/bin/ruby" ]; then
  RUBY_EXE="$DIR/../ruby/.portable/bin/ruby"
fi

# 2) $RUBY env var
if [ -z "$RUBY_EXE" ] && [ -n "$RUBY" ] && [ -x "$RUBY" ]; then
  RUBY_EXE="$RUBY"
fi

# 3) PATH (resolve via command -v)
if [ -z "$RUBY_EXE" ]; then
  RUBY_EXE=$(command -v ruby 2>/dev/null || true)
fi

if [ -z "$RUBY_EXE" ]; then
  echo "[aetheroracle] Ruby not found. Run:" >&2
  echo "  bin/aetheroracle-setup.sh" >&2
  exit 1
fi

# classify the command: brain tier needs bundler, link tier does not
CMD=${1:-}
BRAIN=0
# No subcommand -> enter the Dialog-Kammer (brain tier).
if [ -z "$CMD" ]; then
  BRAIN=1
fi

case "$CMD" in
  ask|chamber|dialog|talk|server|config|context|task|logs|repl|veil|\
  read|cat|inspect|ov|write|new|mv|rename|files|ast|grep|notes|mem|\
  note|history|hist|search|find|aegis|seal|seals)
    BRAIN=1
    ;;
esac

if [ "$BRAIN" -eq 0 ]; then
  # ---- LINK tier: plain ruby, stdlib only ----
  exec "$RUBY_EXE" "$DIR/aetheroracle" "$@"
fi

# ---- BRAIN tier: bundle exec against ruby/Gemfile ----
RUBY_BIN=$(dirname "$RUBY_EXE")

"$RUBY_EXE" -r rubygems -e "gem 'bundler', '2.3.27'" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "[aetheroracle] bundler not installed. Run:" >&2
  echo "  bin/aetheroracle-setup.sh" >&2
  exit 1
fi

BUNDLE_GEMFILE="$DIR/../ruby/Gemfile"
export BUNDLE_GEMFILE
PATH="$RUBY_BIN:$PATH"
export PATH

cd "$DIR/../ruby" || exit 1
exec "$RUBY_EXE" -r rubygems -e "load Gem.bin_path('bundler', 'bundle', '2.3.27')" -- exec "$RUBY_EXE" "$DIR/../ruby/cli.rb" "$@"
