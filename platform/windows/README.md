# windows — AetherOracle on Windows

Two surfaces, two timelines:

1. **The CLI (today)** — the full `aetheroracle` console entry point, running
   locally with *full control* (the whole brain: `ask`, `server`, `config`,
   `task`, `repl`). This file documents it.
2. **The WinUI3 shell (later)** — the native packaged app that embeds the brain
   and owns daemon/file-permission policy per `platform/README.md`. Spec at the
   bottom.

## CLI — one-command full control

The `aetheroracle` CLI has two tiers:

| Tier | Commands | Needs |
|---|---|---|
| **Link** | `peers`, `heartbeat`, `invoke` | Ruby only (pure stdlib) |
| **Brain** | `ask`, `server`, `config`, `task`, `logs`, `repl` | Ruby + DevKit + `bundle install` |

### Setup

```bat
powershell -ExecutionPolicy Bypass -File bin\aetheroracle-setup.ps1
```

This provisions everything in one shot: locates Ruby, pins the gem path to
`ruby/.vendor_bundle`, adds the `x64-mingw-ucrt` platform to the lock, runs
`bundle install`, and smoke-tests the CLI.

If Ruby is missing, install it once (recommended: Ruby + DevKit):

```bat
winget install --id RubyInstallerTeam.RubyWithDevKit.3.1 -e
ridk install 1 3
```

`ridk install 1 3` installs MSYS2 and the development toolchain needed to
compile native gems such as `redcarpet`, `eventmachine`, and
`websocket-driver`. Setup checks that the compiler and make are available
before installing gems and reports the selected Ruby's `ridk` path if needed.
Ruby 3.1 or newer is accepted, including Ruby 3.3. Setup invokes RubyGems
and Bundler through the selected Ruby, regardless of `.cmd`/`.bat` wrappers.

### Why no Rust

Bundler resolves `x64-mingw-ucrt` binaries for `sqlite3` and `tiktoken_ruby`
within the Gemfile's version constraints. The resolved version can depend on
the Ruby version; Ruby 3.3 uses a newer `tiktoken_ruby` than the original
macOS lock. Using these binaries avoids a Rust source build.

### Usage

```bat
bin\aetheroracle.cmd peers                         rem discover peers on the LAN
bin\aetheroracle.cmd invoke mac-oracle "prompt"    rem route a turn to a Mac brain
bin\aetheroracle.cmd ask "prompt"                  rem local brain turn
bin\aetheroracle.cmd server                        rem start the daemon (limen.rb)
bin\aetheroracle.cmd config                        rem show configuration
bin\aetheroracle.cmd task list                     rem task ledger
```

The link tier speaks the same wire contract as `ruby/aether_link.rb`
(scan `4550..4610`, `GET /aether/heartbeat`, `POST /aether/invoke`), so a
Windows box reaches a brain running on a Mac — aetherlink is part of
AetherOracle.

### Prerequisites

- Ruby ≥ 3.1 (RubyInstaller with DevKit) — see above.
- Git — for the `htmldiff` git-sourced gem in the `Gemfile`.

## WinUI3 shell — spec

Implement the `platform/README.md` contract in C#:

- **File permissions** — NTFS ACLs + packaged `AppContainer` capabilities
  (`broadFileSystemAccess`) → `OraclePermissionState`.
- **Daemon lifecycle** — `CreateProcess` (or a Win32 service) for
  `ruby/standalone_daemon.rb`; `canRunDaemon == true`.

Starts when the WinUI3 shell begins.
