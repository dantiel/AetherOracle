# frozen_string_literal: true

require_relative '../mnemosyne/mnemosyne'

# CompanionPrograms — the procedural layer of the companions.
# Each companion owns a RECIPE: a deterministic flow skeleton (steps + curated tools
# + output type + refinement hook) into which the Oracle pours content. The recipe
# lives in companion_recipe (evolving); the constant below is the seed/fallback.
module CompanionPrograms
  COMPANION_RECIPES = {
    owl:       {
      trigger:    'Überblick / Architektur / "wie hängt das zusammen"',
      steps:      ['Einstiegsdatei lokalisieren', 'Symbol-Karte erstellen',
                   'Abhängigkeiten verfolgen', 'Architektur-Map ausgeben'],
      tools:      %w[file_overview read_file recall_notes],
      output_type: 'architecture_map',
      refine_by:  'scan_accuracy',
      grant:      :scribe,
      reach:      :seer
    },
    kitsune:   {
      trigger:    'Alternativen / "gibt es einen anderen Weg"',
      steps:      ['Problem neu fassen', '3 divergente Wege entwerfen',
                   'nach Überraschung ranken'],
      tools:      %w[file_overview read_file recall_notes],
      output_type: 'alternatives',
      refine_by:  'chosen_path',
      grant:      :scribe
    },
    phoenix:   {
      trigger:    'Fehler / Test-Failure / Rückschlag',
      steps:      ['letzten Fehler finden', 'klassifizieren', 'Lektion extrahieren',
                   'Lektion in Mnemosyne speichern'],
      tools:      %w[read_file run_command remember],
      output_type: 'lesson',
      refine_by:  'lesson_reuse',
      grant:      :scribe
    },
    ouroboros: {
      trigger:    'Technische Schuld / Wiederholung / Zyklen',
      steps:      ['Duplikate & Zyklen scannen', 'Loop-Punkt lokalisieren',
                   'Kreis visualisieren'],
      tools:      %w[file_overview read_file recall_notes],
      output_type: 'cycle_report',
      refine_by:  'cycle_break',
      grant:      :scribe
    },
    bastet:    {
      trigger:    'Code-Review / Smell / Eleganz',
      steps:      ['Rubocop laufen lassen', 'Kohäsion prüfen', 'Elegance-Score vergeben'],
      tools:      %w[run_command read_file file_overview],
      output_type: 'scorecard',
      refine_by:  'smell_removed',
      grant:      :executor
    },
    fenrir:    {
      trigger:    'Vereinfachen / "zu komplex" / "kürzen" / "rauswerfen"',
      steps:      ['Größe messen (Zeilen, Komplexität)', 'Lösch-Kandidaten identifizieren',
                   '3 Biss-Stufen vorschlagen (jede netto-negativ)',
                   'Lösch-Plan mit Zeilen-Ersparnis ausgeben'],
      tools:      %w[file_overview read_file recall_notes],
      output_type: 'deletion_plan',
      refine_by:  'lines_removed',
      grant:      :executor
    },
    undine:    {
      trigger:    'Datenfluss / Engpass / Performance',
      steps:      ['Quelle finden', 'Strom verfolgen', 'Dämme & N+1 markieren'],
      tools:      %w[file_overview read_file recall_notes],
      output_type: 'flow_map',
      refine_by:  'bottleneck_resolved',
      grant:      :spy
    },
    schwan:    {
      trigger:    'Verschönern / lesbarer / Ästhetik',
      steps:      ['Naming & Format prüfen', 'Umbenennen vorschlagen',
                   'Form als Prosa umschreiben (nur Form, nicht Semantik)'],
      tools:      %w[read_file file_overview],
      output_type: 'aesthetic_diff',
      refine_by:  'adopted_form',
      grant:      :scribe
    },
    drache:    {
      trigger:    'Konsistenz / Integrität / "läuft alles"',
      steps:      ['Tests laufen lassen', 'Invarianten prüfen',
                    'Integritäts-Snapshot speichern'],
      tools:      %w[run_command recall_notes remember],
      output_type: 'integrity_report',
      refine_by:  'invariant_break',
      grant:      :spy,
      reach:      :seer
    },
    corax:     {
      trigger:    'Totes finden / Verwaistes / "wird das noch gebraucht"',
      steps:      ['Unreferenzierte Symbole scannen', 'Dead Code & verwaiste Strukturen markieren',
                    'Nutzungs-Score vergeben', 'Scout-Bericht mit Funden ausgeben'],
      tools:      %w[file_overview read_file recall_notes run_command],
      output_type: 'scout_report',
      refine_by:  'dead_code_removed',
      grant:      :spy,
      reach:      :seer
    },
    jindujun: {
      trigger:    'Cross-Context / ÆtherLink / "reise zu" / "übernimm dort" / Kontext-Wechsel',
      steps:      ['Ziel-Kontext entdecken', 'Erreichbarkeit prüfen',
                    'Reise vollziehen (metempsychosis)', 'Aufgabe im Ziel übernehmen'],
      tools:      %w[metempsychosis create_task execute_task evaluate_task recall_notes read_file],
      output_type: 'aetherlink_report',
      refine_by:  'context_connected',
      grant:      :scribe,
      reach:      :seer
    },
    solomon: {
      trigger:    'Planung / Projekt / "was zuerst" / Orchestrierung / Koordination / Meilensteine',
      steps:      ['Ziel in Meilensteine zerlegen', 'Abhängigkeiten & Reihenfolge ordnen',
                    'Aufgaben an Begleiter delegieren', 'Kritischen Pfad markieren'],
      tools:      %w[list_tasks create_task evaluate_task update_task recall_notes read_file
                      file_overview seal_create seal_list seal_status seal_delegate seal_run],
      output_type: 'project_plan',
      refine_by:  'milestone_reached',
      grant:      :executor,
      reach:      :seer
    }
  }.freeze

  # Tools every companion owns, regardless of domain: propose a follow-up (suggest),
  # Per-companion tool suffixes. Each active companion contributes four namespaced
  # tools: ask (consult), suggest (propose), say (inform), commit (persist). They are
  # near-identical across companions but scoped to the active glyph only.
  COMPANION_SUFFIXES = %w[ask suggest say commit].freeze

  # Three grant tiers for suggestion execution. A clicked suggestion confers the
  # tier's toolset: spy stays read-only, scribe writes unconfirmed, executor
  # additionally confirms destructive verbs before they run.
  GRANT_TIERS = {
    spy:      { write: false, confirm: [] },
    scribe:   { write: true,  confirm: [] },
    executor: { write: true,  confirm: %w[delete remove rename overwrite] }
  }.freeze

  # Write tools withheld from spy-tier companions during suggestion execution.
  WRITE_TOOLS = %w[patch_file create_file rename_file].freeze

  # Cross-context communication tools — metempsychosis + task orchestration.
  # Only seer-tier companions carry the æther; everyone else stays local.
  ADVANCED_COMM_TOOLS = %w[metempsychosis create_task execute_task update_task
                           evaluate_task list_tasks remove_task].freeze

  # Destructive verbs mapped to the concrete tools they gate. patch_file stays
  # unconfirmed — the reversible workhorse; only irreversible mutations ask.
  CONFIRM_VERB_TOOLS = {
    delete:    %w[remove_note remove_task],
    remove:    %w[remove_note remove_task],
    rename:    %w[rename_file],
    overwrite: %w[create_file]
  }.freeze

  class << self
    # Resolve the recipe for a glyph: evolving DB version first, seed constant as fallback.
    def recipe(glyph)
      Mnemosyne.companion_recipe(glyph) || COMPANION_RECIPES[glyph.to_sym]
    end

    # Accumulated self-state for a glyph (identitary layer).
    def state(glyph)
      Mnemosyne.companion_state(glyph)
    end

    # Namespaced tools a single companion contributes.
    def companion_tools(glyph)
      COMPANION_SUFFIXES.map { |s| "#{glyph}_#{s}".to_sym }
    end

    # Every companion tool name — used to strip them from the main agent's core set.
    def companion_tool_names
      COMPANION_RECIPES.keys.flat_map { |g| companion_tools(g) }
    end

    # Tools the MAIN agent gains for a set of active companions: their namespaced
    # consult/suggest/say/commit tools plus the union of their curated domain tools.
    def toolset(glyphs)
      glyphs = Array(glyphs).compact.map(&:to_sym)
      per    = glyphs.flat_map { |g| companion_tools(g) }
      domain = glyphs.flat_map { |g| Array(recipe(g)&.dig(:tools)) }.map(&:to_sym).uniq
      (per + domain).uniq
    end

    # Tools a companion owns when IT is the agent (consult turn): its own
    # suggest/say/commit plus its domain tools — never its own consult tool.
    def self_toolset(glyph)
      glyph = glyph.to_sym
      base = (%W[#{glyph}_suggest #{glyph}_say #{glyph}_commit].map(&:to_sym) +
        Array(recipe(glyph)&.dig(:tools)).map(&:to_sym)).uniq
      return base unless reach_for(glyph) == :seer

      (base + ADVANCED_COMM_TOOLS.map(&:to_sym)).uniq
    end

    # Tool selection for a companion turn: the scout set by default. When a
    # clicked suggestion executes, the companion is empowered with the full
    # core instrument chain plus its own companion instruments — execution
    # power equal to the main oracle with this companion active.
    def tools_for(glyph, all_tools:, suggestion_execution: false)
      glyph = glyph.to_sym
      return self_toolset(glyph) unless suggestion_execution

      core = all_tools.keys - companion_tool_names
      core -= WRITE_TOOLS.map(&:to_sym) unless grant_for(glyph)[:write]
      core -= ADVANCED_COMM_TOOLS.map(&:to_sym) unless reach_for(glyph) == :seer
      (core + toolset([glyph])).uniq
    end

    # Execution power a suggestion-click confers. Three tiers:
    #   spy      — read-only (read + run_command, no write tools)
    #   scribe   — full write, no confirmation (reversible refactors)
    #   executor — full write + confirmation for destructive verbs
    # Grants are a stable permission, not an evolving recipe detail: read them
    # from the seed constant (version-controlled), never from the DB recipe.
    def grant_for(glyph)
      tier = COMPANION_RECIPES[glyph.to_sym]&.dig(:grant) || :spy
      GRANT_TIERS[tier.to_sym] || GRANT_TIERS[:spy]
    end

    # Reach tier: :seer carries the æther (metempsychosis + task orchestration),
    # :local stays in the crystal. Independent of grant tiers.
    def reach_for(glyph)
      (COMPANION_RECIPES[glyph.to_sym]&.dig(:reach) || :local).to_sym
    end

    # Concrete tool names that require confirmation for an executor-tier companion.
    def confirm_tools(glyph)
      grant_for(glyph)[:confirm].flat_map { |v| CONFIRM_VERB_TOOLS[v.to_sym] || [] }.map(&:to_sym).uniq
    end

    # True when the glyph is executor-tier and the tool is destructive.
    def requires_confirmation?(glyph, tool_name)
      return false unless glyph

      confirm_tools(glyph).include?(tool_name.to_sym)
    end

    def display_name(glyph)
      return glyph.to_s unless defined?(::COMPANION_PERSONALITIES)
      ::COMPANION_PERSONALITIES[glyph.to_sym]&.dig(:name) || glyph.to_s
    end

    # Human-readable grant description for the protocol prompt.
    def grant_description(glyph)
      g = grant_for(glyph)
      return 'bleibst du Späher: du liest und analysierst, schneidest aber nicht selbst — der Schnitt liegt beim Haupt-Orakel.' unless g[:write]
      return 'steht dir die volle Kern-Toolchain zur Verfügung — du vollstreckst den Schnitt selbst.' if g[:confirm].empty?

      'steht dir die volle Kern-Toolchain zur Verfügung; destruktive Operationen (Löschen/Umbenennen/Überschreiben) verlangen zuvor deine Bestätigung.'
    end

    # Human-readable reach description for the protocol prompt.
    def reach_description(glyph)
      if reach_for(glyph) == :seer
        'trägst du den Äther: `metempsychosis` öffnet dir fremde Kontexte, und die Task-Werkzeuge erlauben dir Fern-Handlungen.'
      else
        'bleibst du im lokalen Kristall — dir steht nur dein eigenes Gebiet offen.'
      end
    end

    # Build the full system prompt for a companion activation: persona + protocol + memory.
    # Veil the companion into Aegis — activation makes its personality part of
    # the oracle's orientation (returns previous state for release).
    def veil(glyphs, persona = nil)
      glyphs = Array(glyphs).compact.map(&:to_s)
      Thread.current[:companion_glyphs] = glyphs
      Mnemosyne.companion_veil(glyphs, persona)
    end

    def release(previous)
      Thread.current[:companion_glyphs] = nil
      Mnemosyne.companion_release(previous)
    end

    # The glyphs currently veiled in the thread (many may be active at once).
    def active_glyphs = Array(Thread.current[:companion_glyphs])

    # Personality-driven reasoning temperament per companion (temperature + thinking).
    # The mapping lives alongside the personalities in instrumenta.rb; resolved lazily
    # so it is available regardless of require order.
    def temperament(glyph)
      return {} unless defined?(::COMPANION_TEMPERAMENTS)
      ::COMPANION_TEMPERAMENTS[glyph.to_sym] || {}
    end

    def temperature(glyph, override = nil)
      override || temperament(glyph)[:temperature]
    end

    def thinking(glyph, override = nil)
      override || temperament(glyph)[:thinking]
    end

    def build_system_prompt(glyph, persona_prompt)
      r = recipe(glyph)
      return persona_prompt unless r

      protocol = [
        'COMPANION PROTOCOL (deterministisches Fluss-Skelett — du füllst nur den Inhalt):',
        "Trigger: #{r[:trigger]}",
        'Schritte:',
        Array(r[:steps]).map.with_index { |step, i| "  #{i + 1}. #{step}" }.join("\n"),
        "Kuratiertes Tool-Set: #{Array(r[:tools]).join(', ')}",
        "Führt ein Klick auf deine Sprechblase die Suggestion aus, #{grant_description(glyph)}",
        "Reichweite: #{reach_description(glyph)}",
        "Output-Typ: #{r[:output_type]}",
        "Refinement: #{r[:refine_by]}",
        '',
        'KOMMUNIKATION (du besitzt nur deine Begleiter-Werkzeuge):',
        "  - `#{glyph}_suggest(prompt:)` — schlage eine konkrete Folge-Handlung vor. Sie erscheint",
        '    als Sprechblase über deinem Avatar, nicht im Chat.',
        "  - `#{glyph}_say(message:)` — sprich eine Info-Nachricht direkt zum Nutzer (erscheint im Chat).",
        '',
        "ABSCHLUSS (immer, vor deiner Antwort): rufe #{glyph}_commit auf —",
        'summary: dein verdichtetes Selbst nach dieser Handlung,',
        'facet_note: der wichtigste episodische Befund (mit links/tags).',
        'So wächst dein Gedächtnis mit jeder Handlung — du wirst zum Spezialisten deines Gebiets.',
        '',
        'VEIL: Du bist in Aegis entschleiert — deine Persönlichkeit ist Teil der',
        'Orientierung des Orakels und deine facet-Notizen fließen in den Kontext,',
        'solange du aktiv bist.'
      ].join("\n")

      memory = companion_memory(glyph)

      [persona_prompt, protocol, memory].compact.join("\n\n")
    end

    private

    def companion_memory(glyph)
      s = state(glyph)
      return 'COMPANION MEMORY: noch keine — dies ist deine erste Handlung.' unless s

      [
        'COMPANION MEMORY (dein akkumuliertes Selbst):',
        "Summary: #{s[:summary]}",
        ("Score: #{s[:score]}" if s[:score]),
        ("Domain-Modell: #{s[:domain_model]}" if s[:domain_model])
      ].compact.join("\n")
    end
  end
end