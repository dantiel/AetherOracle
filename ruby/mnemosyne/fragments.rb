# frozen_string_literal: true

require 'time'

class Mnemosyne
  # Fragments -- Stufe 2 der Kaskade: fluechtige Kognition. Fragments are
  # notes as metaformat: same shape (content/tags/links/context_path), same
  # cascade resonance, but transient -- every fragment carries a TTL and
  # decays. They share the polymorphic token substrate with notes
  # (memory_tokens, unit_type 'fragment'). No promotion ladder yet; the
  # documented ladder fragment -> note -> skill -> axiom lives in protocol.md.
  class Fragments
    DEFAULT_TTL = 3600 # seconds

    class << self
      def fragment(content:, tags: nil, links: nil, context_path: nil, ttl: DEFAULT_TTL)
        truncated = Mnemosyne.truncate_note_content(content)
        scope = Notes.derive_context_path(context_path)
        Mnemosyne.db.execute <<~SQL, [truncated, tags&.join(','), links&.join(','), scope, ttl.to_i]
          INSERT INTO fragments (content, tags, links, context_path, ttl, created_at)
          VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        SQL
        id = Mnemosyne.db.last_insert_row_id
        if defined?(Vectors)
          Vectors.index_unit('fragment', id, truncated, tags: tags, links: links, path: scope)
        end
        id
      end

      # Lazily purge expired fragments; returns the number removed. Expiry is
      # checked on every recall so the transient layer never needs a sweeper.
      def expire!
        expired = Mnemosyne.db.execute(
          "SELECT id FROM fragments WHERE datetime(created_at, '+' || ttl || ' seconds') < datetime('now')"
        )
        ids = expired.map { |row| row['id'] }
        return 0 if ids.empty?

        placeholders = (['?'] * ids.size).join(',')
        Mnemosyne.db.execute("DELETE FROM fragments WHERE id IN (#{placeholders})", ids)
        ids.each { |id| Vectors.unindex_unit('fragment', id) if defined?(Vectors) }
        ids.size
      end

      # Same lenses as Notes#recall_notes: :blend (default), :vector,
      # :resonance. The freshness voice only sings in :blend/:resonance --
      # the pure vector path is recency-agnostic.
      def recall_fragments(query, limit: 5, max_content_length: nil, context_path: nil,
                           lens: :blend, channel_weights: nil)
        expire!
        if lens == :vector
          query_tokens = Mnemosyne.tokenize(query)
          map = Vectors.cosine_map(query_tokens, unit_type: 'fragment',
                                   channel_weights: channel_weights || Vectors::DEFAULT_CHANNEL_WEIGHTS)
          return [] if map.empty?

          placeholders = (['?'] * map.size).join(',')
          rows = Mnemosyne.db.execute(
            "SELECT id, content, tags, links, context_path, ttl, created_at FROM fragments WHERE id IN (#{placeholders})",
            map.keys
          )
          return rows.map do |frag|
            frag.transform_keys!(&:to_sym)
            frag[:score] = map.fetch(frag[:id], 0.0)
            frag
          end
          .sort_by { |frag| -frag[:score] }
          .take(limit)
          .map { |frag| Notes.present_note(frag, max_content_length) }
        end

        query_tokens = Mnemosyne.tokenize(query)
        scope = context_path && Notes.normalize_context_path(context_path)
        cosine = if lens != :resonance && defined?(Vectors)
                   Vectors.cosine_map(query_tokens, unit_type: 'fragment',
                                     channel_weights: channel_weights || Vectors::DEFAULT_CHANNEL_WEIGHTS)
                 else
                   {}
                 end

        rows = Mnemosyne.db.execute \
          "SELECT id, content, tags, links, context_path, ttl, created_at FROM fragments #{Resonance.sql_filter(query_tokens)}"

        rows.map do |frag|
          frag.transform_keys!(&:to_sym)
          # created_at is SQLite CURRENT_TIMESTAMP (UTC); the suffix pins the
          # parse so freshness is true age, not shifted by the local zone.
          age = begin
            (Time.now - Time.parse("#{frag[:created_at]} UTC")).to_i
          rescue StandardError
            0
          end
          # Freshness resonance: freshly minted fragments glow (+3), expiring
          # ones dim toward zero -- the transient layer is recency-weighted.
          fresh = [3.0 - 3.0 * age / [frag[:ttl].to_i, 1].max, 0.0].max
          frag[:score] = Resonance.score(frag, query_tokens, scope,
                                         cosine: cosine.fetch(frag[:id], 0.0), fresh: fresh)
          frag[:age] = age
          frag
        end
        .select { |frag| frag[:score].positive? }
        .sort_by { |frag| -frag[:score] }
        .take(limit)
        .map { |frag| Notes.present_note(frag, max_content_length) }
      end
    end
  end
end