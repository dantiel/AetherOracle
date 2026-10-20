# darwin — AetherOracle on macOS

Two surfaces, two timelines:

1. **The CLI (today)** — the full `aetheroracle` RubyGem, installed locally with
   *full control* (the whole brain: `ask`, `server`, `config`, `task`, `repl`).
2. **The native shell (later)** — the Cocoa app that embeds the brain and owns
   daemon/file-permission policy per `platform/README.md`. Spec at the bottom.

## CLI — one-command full control, seven names

AetherOracle is a RubyGem. Installing it on macOS turns the machine into an
Aether OS: the oracle answers to seven names — `aetheroracle`, `aether`,
`oracle`, `oracleaether`, `ae`, `aero`, `orae` — all the same aether in the CLI.

| Tier | Commands | Needs |
|---|---|---|
| **Link** | `peers`, `heartbeat`, `invoke` | Ruby only (pure stdlib) |
| **Brain** | `ask`, `server`, `config`, `task`, `logs`, `repl` | Ruby + Xcode CLT (C gems) |

### Setup

```sh
bin/aetheroracle-setup.sh
```

This does everything in one shot: locates Ruby, builds the gem
(`gem build aetheroracle.gemspec`), installs it (`gem install` — which pulls the
brain tier + its dependencies), and smoke-tests `aetheroracle peers` +
`aetheroracle config`. After it, the seven names are on `PATH`.

If Ruby is missing, install it once (recommended via Homebrew):

```sh
brew install ruby
xcode-select --install
```

`xcode-select --install` fetches the Command Line Tools. It is the *only*
interactive step — it cannot be scripted reliably, and it is only needed to
compile the three C gems (`redcarpet`, `eventmachine`, `websocket-driver`).

### Why no Rust

The two native gems that matter most ship precompiled macOS binaries for the
pinned ranges, so there is no Rust toolchain and no source build for them:

- `sqlite3 1.7.3` → `x86_64-darwin` / `arm64-darwin` (Ruby ≥ 3.1)
- `tiktoken_ruby 0.0.17` → `x86_64-darwin` / `arm64-darwin` (Ruby ≥ 3.1)

### Usage (seven names, one oracle)

```sh
aether peers                         # discover peers on the LAN
ae invoke mac-oracle "prompt"        # route a turn to a brain (aetherlink)
aero ask "prompt"                    # local brain turn
oracle server                        # start the daemon (limen.rb)
orae config                          # show configuration
aetheroracle task list               # task ledger
```

The link tier speaks the same wire contract as `ruby/aether_link.rb`
(scan `4550..4610`, `GET /aether/heartbeat`, `POST /aether/invoke`), so a Mac
box reaches a brain running elsewhere — aetherlink is part of AetherOracle.

### Without `gem install` (source checkout)

The repo ships dev launchers for when you prefer a local checkout over a global
install:

```sh
bin/aetheroracle.sh peers             # link tier: plain ruby, stdlib only
bin/aetheroracle.sh ask "prompt"      # brain tier: bundle exec (ruby/Gemfile)
```

`bin/aetheroracle.sh` routes the link tier through the same dispatcher as the
installed gem (`bin/aetheroracle`); its brain tier runs `ruby/cli.rb` under
`bundle exec` against `ruby/Gemfile` (which still carries the `htmldiff` git
source). Provision the source-checkout vendor bundle once with
`bundle install` from `ruby/`.

## Cocoa shell — spec

Implement the `platform/README.md` contract in Swift/ObjC:

- **File permissions** — App Sandbox entitlement (user-selected file read/write)
  + POSIX mode bits; `TCC` (Full Disk Access) gates the wider filesystem →
  `OraclePermissionState`.
- **Daemon lifecycle** — spawn `standalone_daemon.rb` as a child `NSTask`, watch
  its stdout frames, restart on crash (`AetherCodex/Bridge/RubyBridge.swift`);
  `canRunDaemon == true`.

Starts when the Cocoa shell begins.
