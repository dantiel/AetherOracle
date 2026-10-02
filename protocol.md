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

## Mnemosyne-Kaskade (design)

The memory cascade. Mnemosyne is configured (`.aether`, `.aethercodex`), the
system behaves declaratively — yet every imperative command may change the
aether. Filesystem folders are the root edges of the cascade; contexts can be
wired otherwise (explicit edges, tag wavelengths, companion facets, task/seal
DAGs).

### Stufe 1 — context_path (implemented)

Every note is bound to the folder it was minted in. Recall ranks local (+6) >
ancestors (distance-decayed +4/d, min +1) > tag-resonant foreign branches. The
parent context is **observer-only**: child scopes whisper nothing upward — the
parent harvests, it does not hear.

### Stufe 2 — fragments (implemented)

Fragments are **notes as metaformat**: same shape (content/tags/links/
context_path), same cascade resonance, but transient — every fragment carries
a TTL (default 3600 s) and decays; expired ones are purged lazily on recall.
Freshness is a voice in the score, and fragments share the polymorphic token
substrate with notes.

The promotion ladder (documented, not yet automated):

1. **Fragment** — a transient working thought. Decays unless promoted.
2. **Note** — a durable inscription (`remember`/`create_note`).
3. **Skill** — a procedural unit: recipe-shaped knowledge (steps + tools),
   reusable across contexts. The parent's forge may mint skills from the
   harvest of its child contexts.
4. **Axiom** — *gesichertes Wissen*: a note that survived repeated use and
   contradiction; an invariant of the project cosmos. Promotion criteria:
   stability across turns, corroboration by multiple contexts, and consensus
   of the companions.

### Stufe 3 -- token substrate (implemented) and the neural horizon

Every note and fragment is stored a second time as a term vector
(`memory_tokens`: unit_type/unit_id/token/weight/**kind**, polymorphic).
The substrate is **channeled** -- one network, many observers:

* **content** -- free-text tf weights. Raw markdown alone cannot deliver
  semantic emphasis without special training, so it is only one channel.
* **tag** -- the deliberate semantic emphasis: human-annotated anchors as
  their own vectors. Compound tags (`quantum_gravity`) split into word
  parts so free-text queries resonate with every component. Channel
  weights make tags count double by default.
* **path** -- the structural trace of the cascade (context_path).

A query is a content-channel vector projected onto each channel of every
unit; the channel similarities blend with configurable weights
(`channel_weights:`, default content 1x / tag 2x / path 1x). Search
algorithms are **lenses** over the same substrate:

* `lens: :blend` (default) -- token resonance + cascade + channel-blended
  cosine + freshness, all voices on one score.
* `lens: :vector` -- the pure vector path (`recall_by_vector`): cosine
  only, no literal LIKE filter. The search style the neural Mnemosyne
  speaks.
* `lens: :resonance` -- the pre-vector voice: tokens + cascade, cosine
  silent.

Horizon: embeddings replace tf weights, learned matrices replace cosine --
a small neural Mnemosyne where notes themselves are the tokens, and each
search algorithm collapses the quantum-gravity sink differently.
