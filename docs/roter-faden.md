# Der Rote Faden — Sessions vereint im Flow

> *„Die Gleichzeitigkeit lässt sich nicht in eine Liste pressen — sie ist ein
> Geflecht, das jede neue Stimme mitwebt."*

Dieses Dokument hält fest, **wie** die vielen gleichzeitigen Sessions eines
Projekts zu *einem* Gedankenstrom werden — ohne dass der Anwender je darüber
nachdenken muss, in welcher Session er sich gerade befindet.

## Das mentale Modell (drei Schichten, ein Herz)

| Schicht | Ding | Persistenz | Frage, die sie beantwortet |
|---|---|---|---|
| **Aegis** | `aegis_state` (append-only) | dauerhaft, geteilt | *Was ist der Kurs?* |
| **Hydra** | `aether_sessions` (Roster) | dauerhaft, geteilt | *Wer atmet hier?* |
| **Roter Faden** | `RedThread` (Berechnung) | flüchtig, pro Turn | *Was war gerade im Äther?* |

- **Aegis** ist das *Herz* — eine einzige, von **allen** Prozessen beim Boot
  wiederhergestellte Orientierung (`summary` + `tags`). Jeder Aegis-Schreibzug
  refresht zugleich die eigene Session-Zeile (Korrespondenz, nicht Kopie).
- **Hydra** ist der *Roster der Köpfe* — jede Session (`head == session`)
  registriert sich, jede trägt ihre letzte Orientierung (`aegis_summary`) und
  ihren resumierbaren Zustand (`state_json`).
- **Roter Faden** ist die *Kontinuität dazwischen*: ein deterministisches,
  flash-freies Briefing, das **jeder** nicht-ephemere Turn einatmet.

## Die Antwort auf die Kernfrage

> *„Wie bekommt ein neuer Prompt davon Wind, was in einer anderen Session
> passiert ist?"*

Früher war der `concurrent_gist` (der Slot im System-Prompt) **nur** aktiv,
wenn ein Companion-Flow lief (`Thread.current[:aether_flow]`). Der Anwender in
`chamber`/`ask`/`hydra_terminal` — also genau dort, wo er wirklich redet —
sah **nichts**. Deshalb musste er bei jeder neuen Session neu erklären.

Jetzt feuert `Mnemosyne::RedThread.briefing` in **jedem** nicht-ephemeren Turn
und webt in den `concurrent_gist`:

1. **Geschwister-Sessions** — live **und** kürzlich still/geschlossen, jeweils
   mit ihrer letzten Orientierung (`Hydra.thread_block`). Damit sieht ein neuer
   Kopf, woran ein *fertiger oder verwaister* Kopf zuletzt arbeitete.
2. **Offene Unterziele** — der `AethernautManifest` (die Agenda), jedes
   optional an eine Session gebunden (`AethernautManifest.thread_block`).

Der `GistBus` (in-process Companion-Flows) kommt **zusätzlich** hinzu, wenn
Companions in diesem Prozess atmen — er bleibt, was er war.

## Unterziel ↔ Session

`aethernaut_manifest` trägt jetzt eine `session_id`-Spalte:

- `AethernautManifest.enqueue(..., session_id:)` — beim Anlegen binden.
- `AethernautManifest.bind_session(id, session_id)` — nachträglich binden.
- `AethernautManifest.for_session(session_id)` — „welche Unterziele gehören
  zu dieser Session?"

So wird jedes Unterziel zu einer *Unterschrift* — man sieht, welcher Kopf es
arbeitet, und der Rote Faden zeigt es als `[session: …]`.

## History überdenken (die bewusste Kehre)

Die einst **endlose**, durchsuchbare History (`entries`) bleibt als *Archiv* —
aber sie ist nicht mehr der primäre Erinnerungsweg. Der Rote Faden ersetzt
„alles erinnern" durch **selektives Erinnern**:

| Was | Wo | Rolle |
|---|---|---|
| Momentaner Kurs | Aegis `summary` | *Wo bin ich?* |
| Flüchtige Arbeitsgedanken | `fragments` (TTL) | *Was war eben?* |
| Dauerhafte Struktur | `project_notes` | *Wie ist der Stand?* |
| Archiv | `entries` | *Durchsuchbarkeit, nicht Kontext* |

Redundanz ist damit aufgelöst: **nicht** mehr Prompt + Toolcalls + Antworten
doppelt in die History schreiben, sondern **nur** Fragmente + selektive Notizen
— und der Rote Faden liest die Gegenwart aus dem Substrat.

## Zusammenarbeit der Sessions

- **Wissen voneinander** → `RedThread` (Roster + letzte Orientierung).
- **Arbeiten füreinander** → `metempsychosis` (`from_context`/`to_context`/
  `invoke_in`) und `sessions resume/proceed` (`Hydra.proceed` / `proceed_stale`).
- **Auto-Resume** → ein verwaister Kopf (`stale`) ist resumierbar; der Rote
  Faden zeigt ihn, und `Hydra.proceed` übernimmt Identität + Zustand. (Der
  Flash-Orchestrator `FlashAegis` webt den Kurs; eine explizite
  Resume-Entscheidung ist als nächster Schritt skizziert.)

## Ergebnis für den Anwender

Der Anwender **denkt nicht mehr über Sessions nach**. Er spricht — und der
Turn inhaliert automatisch: den Kurs (Aegis), die Notizen (Aegis-Notes), die
Geschwister + ihre letzte Arbeit (Roter Faden), die offenen Unterziele und die
laufenden Companion-Flows. Das Gespräch knüpft an, weil die Gegenwart mit
eingewoben wird.
