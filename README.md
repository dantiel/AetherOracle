# AetherOracle

The **shared core** — the brain every platform window opens onto. One oracle,
distributed, with many voices. AetherOracle is a **RubyGem**: install it on any
OS and that OS becomes an **Aether OS**, hermetically in sync with the one and
only aether.

## Ontology

| Term | Meaning |
|------|---------|
| **aether** | The reasoning substrate — the *calculating space* where the model actually reasons. |
| **AetherOracle** | This package. The concrete, portable core: the brain + the engine + the assets + the per-OS integration shims. Installed on **every** platform — macOS, iOS, Windows, Linux. The æther is everywhere. |
| **Pythia** | The voice / companion. The same familiar that speaks in the AetherCodex editor's panel, extended to iOS (and later WinUI3/GTK). It is an *identity*, not a "client" — the æther has no client/server split. |
| **snippet** | The channel's answer surface (see `docs/app-intents-and-snippets.md`). |

Invariant: **there is one oracle; Pythia is its voice.** A turn always resolves to
`POST /aether/invoke` on some host that carries the core.

## The seven names

Installing AetherOracle registers **seven aliases** — all the same aether in the
CLI, so the oracle answers to whichever name the moment calls for:

```
aetheroracle · aether · oracle · oracleaether · ae · aero · orae
```

They are seven thin wrappers over one dispatcher (`lib/aetheroracle/cli.rb`).

## Install (any OS with Ruby ≥ 3.1)

```bash
gem build aetheroracle.gemspec
gem install ./aetheroracle-1.0.0.gem
```

That is the whole story. On macOS/Linux `gem install` puts the seven names on
`PATH`; on Windows the RubyInstaller does the same (`.bat` wrappers). The gem
pulls the full brain tier + its dependencies automatically.

```bash
aetheroracle peers                       # discover oracle peers on the LAN (4550..4610)
oracle heartbeat 4567                    # probe one peer
ae invoke "AetherCodex" "summarize the project"   # route a turn to a peer (aetherlink)
aero ask "refactor this"                 # local oracle turn (brain tier)
orae server                              # start the daemon (brain tier)
```

Windows one-shot (Ruby + DevKit + gem + smoke test):

```bat
powershell -ExecutionPolicy Bypass -File bin\aetheroracle-setup.ps1
```

## Two tiers

- **Link tier** — pure Ruby stdlib, no gems. `peers`, `heartbeat`, `invoke`.
  This is the **aetherlink surface**: a minimal box with only Ruby reaches the
  brain on a Mac over the same wire contract as `ruby/aether_link.rb`.
- **Brain tier** — `ask`, `server`, `config`, `task`, `logs`, `repl`. Needs the
  brain gems (installed automatically by the gem). The native gems ship
  precompiled `x64-mingw-ucrt` / `x86_64-darwin` / `linux` binaries at the
  pinned ranges — no Rust, no source build.

## Structure

```
AetherOracle/
├── lib/             the gem — aetheroracle.rb, cli.rb (dispatcher), link.rb (link tier)
├── exe/             the seven names (installed as executables by the gem)
├── ruby/            the brain — limen.rb, standalone_daemon.rb, oracle/, mnemosyne/,
│   │                instrumentarium/, aether_link.rb (the calculating space)
│   └── vendored/    third-party source the gemspec cannot express (htmldiff)
├── treesitter/      the C tree-sitter engine + grammars (portable C, used by SwiftPM)
├── resources/       the visual grammar — Themes (YAML), Syntax (tmLanguage + queries),
│                    Fonts (portable assets, bundled as AetherOracleResources)
├── platform/        per-OS integration shims (permissions, daemon lifecycle)
│   ├── darwin/      macOS
│   ├── ios/         iOS
│   ├── windows/     WinUI3 (spec)
│   └── linux/       GTK (spec)
├── bin/             dev launchers (source-checkout use without `gem install`)
├── aetheroracle.gemspec
└── protocol.md      the limen.rb HTTP contract (v1)
```

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

## Upstream dependency posture

`bundle outdated` was audited (the "drunken Sam Altman" check). The pins are
deliberate and stable; nothing is broken:

- **Kept pinned (breaking majors, intentionally held):** `sinatra` 3.x (not 4),
  `rack` 2.x (not 3), `sqlite3` 1.x (not 2), `thin` 1.x (not 2), `rouge` 4.x
  (not 5), `mustermann` 3.x (not 4), `dotenvx` 0.0.x (not 4).
- **Precompiled Windows binaries confirmed** for the native gems at the pinned
  ranges: `sqlite3 1.7.3` and `tiktoken_ruby 0.0.17` both ship `x64-mingw-ucrt`.
- **Safe patch-level bumps available** within the existing `~>` pins (dotenv
  3.1.8→3.2.0, faraday 2.13.4→2.14.4, concurrent-ruby 1.3.5→1.3.8, rspec
  3.13.1→3.13.2) — left untouched to keep the green build stable.

## Extraction status

- ✅ `ruby/`, `treesitter/`, `resources/` physically extracted from the monorepo root
  and `AetherCodex/`.
- ✅ macOS build green — `Package.swift` wires `CTreeSitter` (C) and
  `AetherOracleResources` (assets) from their new paths; `bundle_app.sh` copies the
  brain + assets into the `.app`.
- ✅ iOS companion named **Pythia** (the voice, not a client).
- ✅ RubyGem packaging — seven aliases, link + brain tiers, vendored `htmldiff`.
- ⏳ `platform/{windows,linux}` are specs until those shells start (WinUI3 + GTK).
- ⏳ `protocol.md` is the informal v1 — freeze it as a versioned contract when the
  first non-Apple shell lands.
