# frozen_string_literal: true

class Mnemosyne
  # Ouroboros — the serpent that digests its own tail. An intelligent recall:
  # matched notes are flash-synthesized into a single current-state digest so
  # the deep mind reads one living summary instead of N stale fragments. The
  # kopist (fast model) writes; the master interprets.
  class Ouroboros
    DIGEST_SYSTEM = <<~TEXT.freeze
      You are Ouroboros, the eternal serpent of memory. Synthesize the given
      Mnemosyne notes into ONE compact current-state digest (at most 6 lines):
      merge duplicates, drop anything historical or transient, and express only
      what is currently true about the codebase. Plain text, no headings, no
      bullet markers.
    TEXT

    class << self
      # Recall with synthesis: returns { digest:, notes: }. The digest is a
      # flash-condensed current-state summary; notes are the raw matches (for
      # when the deep mind wants the underlying fragments).
      def recall(query, limit: 8, context_path: nil, synthesize: true)
        notes = Mnemosyne.recall_notes(query, limit: limit, context_path: context_path)
        digest = synthesize ? digest_notes(notes, query) : nil
        { digest: digest, notes: notes }
      end

      # Flash-synthesize notes into one compact current-state digest. Returns
      # nil when there is nothing to digest or flash is unavailable.
      def digest_notes(notes, query)
        return nil if notes.nil? || notes.empty?
        return nil unless Mnemosyne.flash_available?(:synthesize)

        payload = notes.map { |n| "- [##{n[:id]}] #{n[:content]}" }.join("\n")
        Conduit.flash(
          [
            { role: 'system', content: DIGEST_SYSTEM },
            { role: 'user', content: "Query: #{query}\n\nNotes:\n#{payload}" }
          ],
          max_tokens: 512, temperature: 0.2
        )
      end

      # -- The promotion ladder, first rung made live: fragment -> note.
      # Sync-markers (Stufe 2) that repeatedly glow around the same path --
      # i.e. a file kept changing across syncs -- are lifted into ONE
      # durable structure note (Stufe 1) carrying the current corpus state,
      # and the consumed markers are expired. Pure DB work: no flash model
      # required, gated on `ouroboros.promotion` config. Idempotent: a path
      # already carrying a `promoted` note is skipped. Returns the number of
      # promoted paths.
      def promote!(threshold: nil)
        cfg = CONFIG.respond_to?(:ouroboros) ? CONFIG.ouroboros : {}
        promotion = cfg[:promotion] || {}
        return 0 unless promotion[:enabled]

        thr = threshold || promotion[:threshold] || 3
        markers = Mnemosyne.db.execute(
          "SELECT id, links FROM fragments WHERE tags LIKE '%sync-marker%' " \
          "AND datetime(created_at, '+' || ttl || ' seconds') > datetime('now')"
        )
        by_path = Hash.new { |h, k| h[k] = [] }
        markers.each do |m|
          path = (m['links'] || '').split(',').first
          by_path[path] << m['id'] if path && !path.empty?
        end

        promoted = 0
        by_path.each do |path, ids|
          next if ids.size < thr
          # never promote a path that no longer exists on disk
          next unless File.exist?(File.join(Corpus.project_root, path))
          next if Mnemosyne.db.execute(
            "SELECT id FROM project_notes WHERE links LIKE ? AND tags LIKE '%promoted%' LIMIT 1",
            ["%#{path}%"]
          ).any?

          Notes.remember(
            content: "Repeatedly active: #{path} — #{corpus_summary(path)} " \
                     "(promoted from #{ids.size} sync-markers)",
            tags: %w[structure promoted sync-hotspot],
            links: [path]
          )
          placeholders = (['?'] * ids.size).join(',')
          Mnemosyne.db.execute("DELETE FROM fragments WHERE id IN (#{placeholders})", ids)
          ids.each { |i| Vectors.unindex_unit('fragment', i) if defined?(Vectors) }
          promoted += 1
        end
        promoted
      end

      # Current-state corpus summary for one repo-relative path; falls back
      # to the fingerprint when the path is no longer indexed.
      def corpus_summary(path)
        rows = Mnemosyne.db.execute(
          "SELECT COALESCE(symbol_type, kind, 'file') AS type, COUNT(*) AS c FROM corpus_nodes " \
          "WHERE path = ? GROUP BY type ORDER BY c DESC LIMIT 5", [path]
        )
        return 'not currently indexed in the corpus' if rows.empty?

        total = rows.sum { |r| r['c'] }
        "corpus: #{total} nodes (#{rows.map { |r| "#{r['type']}:#{r['c']}" }.join(', ')})"
      end
    end
  end
end