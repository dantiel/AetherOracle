# AetherOracle

The **shared core** — the brain every platform window opens onto. One oracle,
distributed, with many voices.

## Ontology

| Term | Meaning |
|------|---------|
| **aether** | The reasoning substrate — the *calculating space* where the model actually reasons. |
| **AetherOracle** | This package. The concrete, portable core: the brain + the engine + the assets + the per-OS integration shims. Installed on **every** platform — macOS, iOS, Windows, Linux. The æther is everywhere. |
| **Pythia** | The voice / companion. The same familiar that speaks in the AetherCodex editor's panel, extended to iOS (and later WinUI3/GTK). It is an *identity*, not a "client" — the æther has no client/server split. |
| **snippet** | The channel's answer surface (see `docs/app-intents-and-snippets.md`). |

Invariant: **there is one oracle; Pythia is its voice.** A turn always resolves to
`POST /aether/invoke` on some host that carries the core.

## Structure

```
AetherOracle/
├── ruby/            the brain — limen.rb, standalone_daemon.rb, oracle/, mnemosyne/,
│                    instrumentarium/, aether_link.rb (the calculating space)
├── treesitter/      the C tree-sitter engine + grammars (portable C)
├── resources/       the visual grammar — Themes (YAML), Syntax (tmLanguage + queries),
│                    Fonts (portable assets, bundled as AetherOracleResources)
├── platform/        per-OS integration shims (permissions, daemon lifecycle)
│   ├── darwin/      macOS
│   ├── ios/         iOS
│   ├── windows/     WinUI3 (spec)
│   └── linux/       GTK (spec)
├── bin/             the `aetheroracle` CLI (link tier is pure stdlib — runs
│                    on Windows/Linux too; brain tier needs `bundle install`)
└── protocol.md      the limen.rb HTTP contract (v1)
```

## CLI

`bin/aetheroracle` is the console entry point. It has two tiers:

- **Link tier** — pure Ruby stdlib, no gems. Runs on **any** platform with Ruby
  (macOS, Windows, Linux). This is the *aetherlink surface*: discover peers and
  route turns to a remote oracle over the LAN.
- **Brain tier** — needs the `ruby/` gems (`cd ruby && bundle install`). Runs
  where the calculating space itself lives (`ask`, `server`, `config`, `task`).

```bash
aetheroracle peers                        # discover oracle peers on the LAN (4550..4610)
aetheroracle heartbeat 4567               # probe one peer
aetheroracle invoke "AetherCodex" "summarize the project"   # route a turn to a peer
aetheroracle ask "refactor this"          # local oracle turn (brain tier)
aetheroracle server                       # start the daemon (brain tier)
```

On Windows the same two tiers run via `bin/aetheroracle.cmd`, and the full
*brain tier* (local `ask`/`server`/`config`/`task`) is one command away:

```bat
powershell -ExecutionPolicy Bypass -File bin\aetheroracle-setup.ps1

aetheroracle.cmd peers
aetheroracle.cmd invoke mac-oracle "what is the aether?"
aetheroracle.cmd ask "refactor this"     # local brain — full control
aetheroracle.cmd server                  # run the daemon on Windows
```

`aetheroracle-setup.ps1` pins the gems to `ruby/.vendor_bundle`, adds the
`x64-mingw-ucrt` platform to the lock, and `bundle install`s. See
`platform/windows/README.md` for prerequisites (RubyInstaller + DevKit).

The link tier speaks the **same contract as `ruby/aether_link.rb`** (scan
`4550..4610`, `GET /aether/heartbeat`, `POST /aether/invoke`), so a Windows or
Linux box reaches the brain running on a Mac. The aether is everywhere; the
voice finds it.

## Who owns the daemon?

The **daemon is part of the brain** — `ruby/standalone_daemon.rb` is the *running
form* of the calculating space, so it lives here in `AetherOracle`. But **how** a
long-lived process is started, stopped, and watched differs per OS. The division:

- **AetherOracle** owns the daemon *implementation* and the per-OS *lifecycle
  shims* (`ensureDaemonRunning` / `stop` / `health`) — see `platform/`.
- **The native shells** own the *policy* — when to start/stop, how to respond to a
  crash. On macOS the editor spawns the daemon as a child `NSTask` via the darwin
  shim; on Windows/Linux the shell will do the equivalent (CreateProcess / fork+exec)
  through their shims. On **iOS there is no daemon** — the companion reaches a
  peer's daemon over the LAN, and the iOS shim reports `canRunDaemon == false`.

So: **the daemon ships with AetherOracle; the apps run it.** One brain, many
policies.

## Extraction status

- ✅ `ruby/`, `treesitter/`, `resources/` physically extracted from the monorepo root
  and `AetherCodex/`.
- ✅ macOS build green — `Package.swift` wires `CTreeSitter` (C) and
  `AetherOracleResources` (assets) from their new paths; `bundle_app.sh` copies the
  brain + assets into the `.app`.
- ✅ iOS companion renamed `AetherClient` → **`Pythia`** (the voice, not a client).
- ⏳ `platform/{windows,linux}` are specs until those shells start (WinUI3 + GTK).
- ⏳ `protocol.md` is the informal v1 — freeze it as a versioned contract when the
  first non-Apple shell lands.