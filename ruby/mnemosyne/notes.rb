# frozen_string_literal: true

require_relative '../aether_link'

class Mnemosyne
  # Notes — notes
  class Notes
    class << self
        def get_note(note_id)
          note = Mnemosyne.db.execute('SELECT * FROM project_notes WHERE id = ? LIMIT 1', [note_id]).first
          note&.transform_keys!(&:to_sym)
          note
        end


        # Retrieve a note by ID

        # Recall with a lens -- the same substrate, different observers:
        #   :blend     (default) all voices: token resonance + cascade +
        #              channel-blended cosine
        #   :vector    pure vector path, cosine only, no literal LIKE filter
        #   :resonance pre-vector voice: tokens + cascade, cosine silent
        def recall_notes(query, limit: 5, max_content_length: nil, context_path: nil,
                         lens: :blend, channel_weights: nil)
          return Vectors.recall_by_vector(query, limit: limit, max_content_length: max_content_length,
                                          context_path: context_path,
                                          channel_weights: channel_weights || Vectors::DEFAULT_CHANNEL_WEIGHTS) if lens == :vector

          query_tokens = Mnemosyne.tokenize(query)
          scope = context_path && normalize_context_path(context_path)
          cosine = if lens != :resonance && defined?(Vectors)
                     Vectors.cosine_map(query_tokens, unit_type: 'note',
                                       channel_weights: channel_weights || Vectors::DEFAULT_CHANNEL_WEIGHTS)
                   else
                     {}
                   end

          notes = Mnemosyne.db.execute \
            "SELECT id, content, tags, links, context_path, created_at FROM project_notes #{Resonance.sql_filter(query_tokens)}"

          notes.map do |note|
            note.transform_keys!(&:to_sym)
            note[:score] = Resonance.score(note, query_tokens, scope, cosine: cosine.fetch(note[:id], 0.0))
            note
          end
          .select { |note| note[:score].positive? }
          .sort_by { |note| -note[:score] }
          .take(limit)
          .map { |note| present_note(note, max_content_length) }
        end

        # Present a recalled unit: bound content length, validate links.
        # Shared by notes and fragments -- the metaformat renders alike.
        def present_note(note, max_content_length)
          if max_content_length && note[:content] && note[:content].length > max_content_length
            note[:content] =
              Mnemosyne.truncate_note_content(note[:content], max_length: max_content_length)
          end
          if note[:links]
            note[:links] = note[:links].split(',').map do |link|
              if Argonaut.file_exists? link
                link
              else
                "~~#{link}~~ (path not found)"
              end
            end.join ','
          end
          note
        end

        def create_note(content:, links: nil, tags: nil, context_path: nil)
          truncated_content = Mnemosyne.truncate_note_content(content)
          scope = derive_context_path(context_path)
          Mnemosyne.db.execute "
            INSERT INTO project_notes (content, links, tags, context_path, created_at)
            VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)",
                     [truncated_content, links&.join(','), tags&.join(','), scope]
          id = Mnemosyne.db.last_insert_row_id
          if defined?(Vectors)
            Vectors.index_unit('note', id, truncated_content, tags: tags, links: links, path: scope)
          end
          id
        end


        # Alias for create_note for backward compatibility

        def remember(content:, links: nil, tags: nil, context_path: nil)
          create_note content: content, links: links, tags: tags, context_path: context_path
        end

        # The context path (folder) a note is bound to. Explicit scope wins;
        # otherwise the Aegis working_dir; otherwise the project root. This is
        # the cascade's root edge: a note minted in `ruby/oracle` resounds in
        # every scope beneath it.
        def derive_context_path(explicit)
          raw = explicit || Mnemosyne.working_dir || CONFIG.project_root
          raw = CONFIG.project_root if raw.to_s.strip.empty?
          normalize_context_path raw
        end

        def normalize_context_path(path)
          File.expand_path(path.to_s).tr('\\', '/').sub(%r{/+$}, '')
        end


        # Fetch notes by links (for Argonaut file overview)

        def fetch_notes_by_links(links)
          links = [links] unless links.is_a? Array

          result = Mnemosyne.db.execute("SELECT * FROM project_notes WHERE #{(['links LIKE ?'] * links.count).join ' OR '}",
                              links.map { |link| "%#{link}%" })

          # Handle nil result gracefully
          return [] unless result

          result.each do |note|
            note.transform_keys!(&:to_sym)
          end
        end



        def update_note(id, content: nil, links: nil, tags: nil)
          truncated_content = Mnemosyne.truncate_note_content(content) if content
          # COALESCE preserves existing links/tags when a partial update omits
          # them ??? otherwise `remember(id:)` with only new content wipes them.
          Mnemosyne.db.execute \
            'UPDATE project_notes SET content = COALESCE(?, content), links = COALESCE(?, links), tags = COALESCE(?, tags), updated_at = CURRENT_TIMESTAMP WHERE id = ?', [
              truncated_content || content, links&.join(','), tags&.join(','), id
            ]
          if defined?(Vectors) && content
            # Re-index with the unit's current tags/path -- the vector must
            # mirror the row after the COALESCE merge, not just the new text.
            row = get_note(id)
            Vectors.index_unit('note', id, truncated_content || content,
                               tags: row && row[:tags]&.split(','),
                               path: row && row[:context_path])
          end
        end


        # Remove note by id

        def remove_note(id)
          Mnemosyne.db.execute 'DELETE FROM project_notes WHERE id = ?', [id]
          Vectors.unindex_unit('note', id) if defined?(Vectors)
        end

        # Create a *linked* note — a pointer to a knowledge unit in another
        # context's Mnemosyne, not a copy. The content stays at the source;
        # this note carries `context`, `source_note_id` and an
        # `aether://<context>/note/<id>` link so the target can resolve it
        # on demand via ÆtherLink. Link, not copy: one unit, many pointers.
        def link_note(source_context:, source_note_id:, content: nil, tags: nil, links: nil)
          pointer = "aether://#{source_context}/note/#{source_note_id}"
          all_links = (Array(links) + [pointer]).uniq
          all_tags = Array(tags) + ["link:#{source_context}", "source_context:#{source_context}", "source_note:#{source_note_id}"]
          summary = content.to_s.empty? ? "↗ #{pointer}" : content
          truncated = Mnemosyne.truncate_note_content(summary)
          Mnemosyne.db.execute <<~SQL, [truncated, all_links.join(','), all_tags.uniq.join(','), source_context, source_note_id.to_i]
            INSERT INTO project_notes (content, links, tags, context, source_note_id, created_at)
            VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
          SQL
          Mnemosyne.db.last_insert_row_id
        end

        # Resolve a linked note's source: fetch the knowledge unit from the
        # named peer context by id. Returns nil when the context is unreachable.
        # This is the "link, don't copy" read path — the unit is pulled through
        # ÆtherLink only when actually needed.
        def resolve_linked_note(source_context, source_note_id)
          result = AetherLink.query(source_context, '/aether/note', { id: source_note_id.to_i })
          return nil unless result.is_a?(Hash) && result[:ok]
          result[:note]&.transform_keys(&:to_sym)
        end

        # List notes bound to a specific context (provenance search) — used to
        # surface which other Mnemosynes this context already points into.
        def notes_for_context(context)
          Mnemosyne.db.execute(
            'SELECT id, content, tags, links, context, source_note_id, created_at FROM project_notes WHERE context = ? ORDER BY created_at DESC',
            [context]
          ).map { |n| n.transform_keys!(&:to_sym) }
        end



    end
  end
end