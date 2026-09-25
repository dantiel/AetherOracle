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

        def recall_notes(query, limit: 5, max_content_length: nil)
          query_tokens = Mnemosyne.tokenize(query)

          sql_query = if query_tokens.empty?
                        ''
                      else
                        'WHERE ' + (%w[content tags links].map do |field|
                          query_tokens&.map { |keyword| "#{field} LIKE '%#{keyword}%'" }&.join ' OR '
                        end.join ' OR ')
                      end

          notes = Mnemosyne.db.execute \
            "SELECT id, content, tags, links, created_at FROM project_notes #{sql_query}"

          notes.map do |note|
            note.transform_keys!(&:to_sym)

            score = 0

            if query_tokens.empty?
              score = 1
            else
              # Enhanced scoring with path matching for better file relevance
              score += 4 * (query_tokens & Mnemosyne.tokenize(note[:content])).size
              score += 3 * (query_tokens & Mnemosyne.tokenize(note[:tags])).size
              score += 2 * (query_tokens & Mnemosyne.tokenize(note[:links])).size

              # Boost score for exact path matches in links
              score += 5 if note[:links] && query_tokens.any? { |token| note[:links].include?(token) }
            end

            { **note, score: }
          end
          .select { |note| note[:score].positive? }
               .sort_by { |note| -note[:score] }
               .take(limit)
               .map do |note|
            # Apply content length limit if specified
            # puts "RECALL NOTES: #{note}"
            if max_content_length && note[:content] && note[:content].length > max_content_length
              note[:content] =
                Mnemosyne.truncate_note_content(note[:content], max_length: max_content_length)
            end
            # puts "RECALL NOTES: #{note[:links]}"
            if note[:links]
              note[:links] = note[:links].split(',').map do |link|
                if Argonaut.file_exists? link
                  link
                else
                  "~~#{link}~~ (path not found)"
                end
              end.join ','
            end
            note # Ensure we return the note hash, not the links string
          end
        end

        def create_note(content:, links: nil, tags: nil)
          truncated_content = Mnemosyne.truncate_note_content(content)
          Mnemosyne.db.execute "
            INSERT INTO project_notes (content, links, tags, created_at)
            VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
                     [truncated_content, links&.join(','), tags&.join(',')]
          Mnemosyne.db.last_insert_row_id
        end


        # Alias for create_note for backward compatibility

        def remember(content:, links: nil, tags: nil)
          create_note content: content, links: links, tags: tags
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
          # them — otherwise `remember(id:)` with only new content wipes them.
          Mnemosyne.db.execute \
            'UPDATE project_notes SET content = COALESCE(?, content), links = COALESCE(?, links), tags = COALESCE(?, tags), updated_at = CURRENT_TIMESTAMP WHERE id = ?', [
              truncated_content || content, links&.join(','), tags&.join(','), id
            ]
        end


        # Remove note by id

        def remove_note(id)
          Mnemosyne.db.execute 'DELETE FROM project_notes WHERE id = ?', [id]
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