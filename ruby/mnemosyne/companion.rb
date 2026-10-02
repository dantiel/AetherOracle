# frozen_string_literal: true

class Mnemosyne
  # Companion — the companion facets of Pythia's shared memory.
  # One crystal, many facets: every companion reads and writes through its own
  # facet, but the store is single. Three layers:
  #   * episodic    → facet-tagged project_notes  (shared store, facet-filtered)
  #   * procedural  → companion_recipe             (distilled action recipes)
  #   * identitary  → companion_state              (accumulated self per glyph)
  class Companion
    FACET_TAG_PREFIX = 'facet:'

    class << self
      # -- Identitary layer (accumulated self) --

      def save_state(glyph:, summary:, tags: [], score: nil, domain_model: nil)
        Mnemosyne.db.execute \
          'INSERT INTO companion_state (glyph, summary, tags, score, domain_model, created_at) ' \
          'VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)',
          [glyph.to_s, summary, Array(tags).join(','), score, domain_model]
      end

      def load_state(glyph, limit: 1)
        rows = Mnemosyne.db.execute \
          'SELECT glyph, summary, tags, score, domain_model, created_at FROM companion_state ' \
          'WHERE glyph = ? ORDER BY created_at DESC, id DESC LIMIT ?', [glyph.to_s, limit]
        rows.map { |r| r.transform_keys(&:to_sym) }
      end

      def state(glyph)
        load_state(glyph, limit: 1).first
      end

      # -- Procedural layer (action recipes) --

      def save_recipe(glyph:, trigger:, steps:, tools:, output_type:, refine_by: nil)
        Mnemosyne.db.execute \
          'INSERT INTO companion_recipe (glyph, trigger, steps, tools, output_type, refine_by, created_at) ' \
          'VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)',
          [glyph.to_s, trigger, JSON.generate(Array(steps)), JSON.generate(Array(tools)),
           output_type, refine_by]
      end

      def load_recipe(glyph, limit: 1)
        rows = Mnemosyne.db.execute \
          'SELECT glyph, trigger, steps, tools, output_type, refine_by, created_at FROM companion_recipe ' \
          'WHERE glyph = ? ORDER BY created_at DESC, id DESC LIMIT ?', [glyph.to_s, limit]
        rows.map do |r|
          r.transform_keys(&:to_sym).tap do |h|
            h[:steps] = Mnemosyne.safe_parse_json(h[:steps], [])
            h[:tools] = Mnemosyne.safe_parse_json(h[:tools], [])
          end
        end
      end

      def recipe(glyph)
        load_recipe(glyph, limit: 1).first
      end

      # -- Episodic layer (facet-tagged notes) --

      def remember_facet(content:, facet:, links: nil, tags: [])
        tags = Array(tags) + ["#{FACET_TAG_PREFIX}#{facet}"]
        Mnemosyne.create_note content: content, links: links, tags: tags
      end

      def recall_facet(facet, query: '', limit: 5, max_content_length: nil)
        facet_tag = "#{FACET_TAG_PREFIX}#{facet}"
        notes = Mnemosyne.recall_notes("#{facet_tag} #{query}", limit: limit * 3,
                                                                  max_content_length: max_content_length)
        notes.select { |n| n[:tags].to_s.include?(facet_tag) }.take(limit)
      end

      # -- The Veil: Aegis ↔ Companion integration --
      # When a companion activates, the oracle veils itself in that facet:
      # the persona + accumulated self become part of the Aegis orientation,
      # and the facet tag opens the episodic memory flow into recall_aegis_notes.
      # Returns the previous aegis state for release.

      def active_glyphs
        existing_tags(current_aegis).filter_map do |t|
          t.to_s.start_with?(FACET_TAG_PREFIX) ? t.to_s.delete_prefix(FACET_TAG_PREFIX).to_sym : nil
        end.uniq
      end

      # Veil companions into Aegis cumulatively: activation adds each facet to
      # the orientation — many may be active at once. Returns the previous aegis
      # state so a full release can restore it.
      def veil(glyphs, persona = nil)
        previous = current_aegis
        glyphs = (active_glyphs + Array(glyphs).map(&:to_sym)).uniq

        Mnemosyne.aegis = build_aegis_state(glyphs, persona, previous)
        Mnemosyne.save_aegis_state(**Mnemosyne.aegis)
        previous
      end

      # Release a single companion facet — the others stay veiled.
      def unveil(glyph)
        glyphs = active_glyphs - [glyph.to_sym]
        Mnemosyne.aegis = build_aegis_state(glyphs, nil, current_aegis)
        Mnemosyne.save_aegis_state(**Mnemosyne.aegis)
        current_aegis
      end

      # Release the veil: restore the orientation the oracle held before activation.
      def release(previous)
        return nil unless previous

        Mnemosyne.aegis = previous.dup
        Mnemosyne.save_aegis_state(**Mnemosyne.aegis)
        previous
      end

      private

      # Rebuild the Aegis orientation for a set of active glyphs: the base
      # (non-companion) summary is preserved, the companion essence is derived
      # deterministically from the current facet set.
      def build_aegis_state(glyphs, persona, previous)
        facet_tags = glyphs.map { |g| "#{FACET_TAG_PREFIX}#{g}" }
        summaries  = glyphs.filter_map { |g| load_state(g, limit: 1).first&.dig(:summary) }
        essence    = if glyphs.empty?
                       nil
                     else
                       (['COMPANION VEILED'] + glyphs.map { |g| g.to_s.capitalize } +
                         [persona] + summaries).compact.uniq.join("\n")
                     end

        {
          tags:        (existing_tags(previous).reject { |t| t.to_s.start_with?(FACET_TAG_PREFIX) } + facet_tags).uniq,
          summary:     [present_or_nil(base_summary(previous)), present_or_nil(essence)].compact.join("\n"),
          temperature: previous[:temperature],
          working_dir: previous[:working_dir],
          thinking:    previous[:thinking]
        }
      end

      def base_summary(aegis_state)
        summary = aegis_state[:summary].to_s
        idx = summary.index('COMPANION VEILED')
        idx ? summary[0...idx].strip : summary.strip
      end

      def current_aegis
        Mnemosyne.aegis || { tags: [], summary: '', temperature: 1.0,
                             working_dir: nil, thinking: nil }
      end

      def existing_tags(aegis_state)
        tags = aegis_state[:tags]
        tags = tags.split(',') if tags.is_a?(String)
        Array(tags).compact
      end

      def present_or_nil(text)
        text.to_s.strip.empty? ? nil : text
      end
    end
  end
end