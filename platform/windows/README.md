# windows — AetherOracle on Windows

Two surfaces, two timelines:

1. **The CLI (today)** — the full `aetheroracle` RubyGem, installed locally with
   *full control* (the whole brain: `ask`, `server`, `config`, `task`, `repl`).
2. **The WinUI3 shell (later)** — the native packaged app that embeds the brain
   and owns daemon/file-permission policy per `platform/README.md`. Spec at the
   bottom.

## CLI — one-command full control, seven names

AetherOracle is a RubyGem. Installing it on Windows turns the machine into an
Aether OS: the oracle answers to seven names — `aetheroracle`, `aether`,
`oracle`, `oracleaether`, `ae`, `aero`, `orae` — all the same aether in the CLI.

| Tier | Commands | Needs |
|---|---|---|
| **Link** | `peers`, `heartbeat`, `invoke` | Ruby only (pure stdlib) |
| **Brain** | `ask`, `server`, `config`, `task`, `logs`, `repl` | Ruby + DevKit (C gems) |

### Setup

```bat
powershell -ExecutionPolicy Bypass -File bin\aetheroracle-setup.ps1
```

This does everything in one shot: locates Ruby, builds the gem
(`gem build aetheroracle.gemspec`), installs it (`gem install` — which pulls the
brain tier + its dependencies), and smoke-tests `aetheroracle peers` +
`aetheroracle config`. After it, the seven names are on `PATH`.

If Ruby is missing, install it once (recommended: Ruby + DevKit):

```bat
winget install --id RubyInstallerTeam.RubyWithDevKit.3.1 -e
ridk install 1 3
```

`ridk install 1 3` fetches the MSYS2/mingw toolchain. It is the *only*
interactive step — it cannot be scripted reliably, and it is only needed to
compile the three C gems (`redcarpet`, `eventmachine`, `websocket-driver`).

### Why no Rust

The two native gems that matter most ship precompiled Windows binaries for the
pinned ranges, so there is no Rust toolchain and no source build for them:

- `sqlite3 1.7.3` → `x64-mingw-ucrt` (Ruby ≥ 3.1)
- `tiktoken_ruby 0.0.17` → `x64-mingw-ucrt` (Ruby ≥ 3.1)

### Usage (seven names, one oracle)

```bat
aether peers                         rem discover peers on the LAN
ae invoke mac-oracle "prompt"        rem route a turn to a Mac brain (aetherlink)
aero ask "prompt"                    rem local brain turn
oracle server                        rem start the daemon (limen.rb)
orae config                          rem show configuration
aetheroracle task list               rem task ledger
```

The link tier speaks the same wire contract as `ruby/aether_link.rb`
(scan `4550..4610`, `GET /aether/heartbeat`, `POST /aether/invoke`), so a
Windows box reaches a brain running on a Mac — aetherlink is part of
AetherOracle.

### Without `gem install` (source checkout)

The repo ships dev launchers for when you prefer a local checkout over a global
install:

```bat
bin\aetheroracle.cmd peers              rem link tier: plain ruby, stdlib only
bin\aetheroracle.cmd ask "prompt"       rem brain tier: bundle exec (ruby/Gemfile)
```

`bin\aetheroracle.cmd` routes the link tier through the same dispatcher as the
installed gem (`bin/aetheroracle`); its brain tier runs `ruby/cli.rb` under
`bundle exec` against `ruby/Gemfile` (which still carries the `htmldiff` git
source).

## WinUI3 shell — spec

Implement the `platform/README.md` contract in C#:

- **File permissions** — NTFS ACLs + packaged `AppContainer` capabilities
  (`broadFileSystemAccess`) → `OraclePermissionState`.
- **Daemon lifecycle** — `CreateProcess` (or a Win32 service) for
  `ruby/standalone_daemon.rb`; `canRunDaemon == true`.

Starts when the WinUI3 shell begins.
