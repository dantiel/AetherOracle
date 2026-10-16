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
    end
  end
end