# AetherOracle — protocol (limen.rb v1)

The wire contract every window speaks to reach the oracle. This is the boundary
that makes "one oracle, many voices" true across platforms.

## Transport

- HTTP/1.1 over LAN. The daemon (`ruby/standalone_daemon.rb`) binds `0.0.0.0`.
- Default port **4567** (`AETHER_PORT` override, `config.rb DEFAULT_CONFIG[:port]`).
- Discovery scan range **4550…4610** (mirrors `aether_link.rb AetherLink.SCAN_RANGE`).

## Endpoints

| Endpoint | Method | Purpose | Payload → Response |
|----------|--------|---------|--------------------|
| `/aether/heartbeat` | GET | discovery | → `{ name, port, path, version, capabilities, busy }` |
| `/aether/invoke` | POST | a turn | `{ prompt, type:"chat", from_context, active_companions? }` → `{ answer, html?, source_context? }` |
| `/aether/aegis` | GET | reasoning state | → `{ thinking, temperature, summary, tags, working_dir? }` |
| `/aether/voices` | GET | vox roster | → `{ voices: [{ name, locale, language }] }` |
| `/aether/speak` | POST | speak | `{ text, voice? }` → `{ ok }` |

## Invariants

1. Every turn resolves to `POST /aether/invoke` — never a hardcoded model call.
2. The companion roster is mirrored, not duplicated: `CompanionVoice` (intents) ↔
   `pythiaCompanions` (runtime) ↔ daemon `ready` frame ↔ `chamber.html`.
3. A turn never forces an app launch (snippets are non-modal).
4. `OracleConnectionStore` is the single persistence point for the last-reached peer.

## Versioning

This is the informal **v1**. It becomes a frozen, versioned contract (semver +
capability negotiation in `/aether/heartbeat.capabilities`) when the first
non-Apple shell (WinUI3/GTK) is wired, so all four shells converge on one truth.
