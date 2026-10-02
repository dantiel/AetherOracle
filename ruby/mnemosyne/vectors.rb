# frozen_string_literal: true

class Mnemosyne
  # Vectors -- Stufe 3 der Kaskade: das Token-Substrat. Every unit (note or
  # fragment) is stored a second time as a term vector in memory_tokens
  # (polymorphic: unit_type/unit_id/token/weight/kind). This is the
  # data-structure level where notes become tokens -- one network, many
  # observers: each search algorithm is a lens that collapses the same
  # substrate differently.
  #
  # Channels (kind): 'content' = free text tf weights, 'tag' = explicit
  # semantic emphasis (the human-annotated dimension raw markdown cannot
  # deliver without training), 'path' = the structural trace of the cascade.
  # A query (free text) is a content-channel vector; cosine against the
  # tag-channel measures how much of it resonates with deliberate labels.
  class Vectors
    DEFAULT_CHANNEL_WEIGHTS = { content: 1.0, tag: 2.0, path: 1.0 }.freeze

    class << self
      def index_unit(unit_type, unit_id, content, tags: nil, links: nil, path: nil)
        unindex_unit(unit_type, unit_id)
        channels = {
          'content' => content.to_s,
          'tag'     => tags.to_a.join(' '),
          'path'    => path.to_s
        }
        channels.each do |kind, text|
          # The tag channel is the deliberate semantic emphasis: compound
          # anchors like 'quantum_gravity' split into their word parts so a
          # free-text query resonates with every component of the label.
          text = text.gsub(/[_\-\/]/, ' ') if kind == 'tag'
          tf = Hash.new(0)
          text.downcase.scan(/\w+/).each do |tok|
            tf[tok] += 1 unless Mnemosyne::STOP_WORDS.include?(tok)
          end
          total = tf.values.sum.to_f
          next if total.zero?

          tf.each do |token, count|
            Mnemosyne.db.execute(
              'INSERT INTO memory_tokens (unit_type, unit_id, token, weight, kind) VALUES (?, ?, ?, ?, ?)',
              [unit_type.to_s, unit_id.to_i, token, count / total, kind]
            )
          end
        end
      end

      def unindex_unit(unit_type, unit_id)
        Mnemosyne.db.execute('DELETE FROM memory_tokens WHERE unit_type = ? AND unit_id = ?',
                             [unit_type.to_s, unit_id.to_i])
      end

      # Rebuild the whole substrate from the durable layers (notes + live
      # fragments). Idempotent -- the vector index is derived state.
      def rebuild
        Mnemosyne.db.execute('DELETE FROM memory_tokens')
        Mnemosyne.db.execute('SELECT id, content, tags, links, context_path FROM project_notes').each do |row|
          index_unit('note', row['id'], row['content'], tags: row['tags'].to_s.split(','), path: row['context_path'])
        end
        Mnemosyne.db.execute('SELECT id, content, tags, links, context_path FROM fragments').each do |row|
          index_unit('fragment', row['id'], row['content'], tags: row['tags'].to_s.split(','), path: row['context_path'])
        end
      end

      # Lazily seed the substrate for pre-Stufe-3 databases.
      def ensure_indexed
        count = Mnemosyne.db.execute('SELECT COUNT(*) AS c FROM memory_tokens').first['c'].to_i
        rebuild if count.zero?
      end

      # Query tokens -> { unit_id => channel-blended cosine } for one
      # unit_type (nil = the whole substrate). The query is a content vector;
      # it is projected onto each channel of every unit, and the channel
      # similarities blend with channel_weights -- tags (2x by default) are
      # the deliberate semantic emphasis. Vectors are tf-weighted.
      def cosine_map(query_tokens, unit_type: nil, channel_weights: nil)
        return {} if query_tokens.empty?

        channel_weights ||= DEFAULT_CHANNEL_WEIGHTS

        conds = []
        params = []
        if unit_type
          conds << 'unit_type = ?'
          params << unit_type.to_s
        end
        placeholders = (['?'] * query_tokens.size).join(',')
        conds << "token IN (#{placeholders})"
        params += query_tokens.to_a

        rows = Mnemosyne.db.execute(
          "SELECT unit_id, kind, SUM(weight) AS raw, SUM(weight * weight) AS sq FROM memory_tokens WHERE #{conds.join(' AND ')} GROUP BY unit_id, kind",
          params
        )

        query_norm = Math.sqrt(query_tokens.size)
        total_w = channel_weights.values.sum.to_f
        per_unit = Hash.new { |h, k| h[k] = Hash.new(0.0) }
        rows.each do |row|
          cos = row['sq'].to_f.positive? ? row['raw'].to_f / (Math.sqrt(row['sq']) * query_norm) : 0.0
          w = channel_weights[row['kind'].to_sym] || channel_weights[row['kind'].to_s] || 1.0
          per_unit[row['unit_id']][row['kind']] = cos * w
        end
        per_unit.transform_values { |chans| total_w.positive? ? chans.values.sum / total_w : 0.0 }
      end

      # The pure vector path -- recall without literal LIKE filtering, ranked
      # by channel-blended cosine only. This is the search style the neural
      # Mnemosyne speaks.
      def recall_by_vector(query, limit: 5, max_content_length: nil, context_path: nil, channel_weights: nil)
        query_tokens = Mnemosyne.tokenize(query)
        return [] if query_tokens.empty?

        ensure_indexed
        map = cosine_map(query_tokens, unit_type: 'note', channel_weights: channel_weights)
        return [] if map.empty?

        placeholders = (['?'] * map.size).join(',')
        rows = Mnemosyne.db.execute(
          "SELECT id, content, tags, links, context_path, created_at FROM project_notes WHERE id IN (#{placeholders})",
          map.keys
        )
        rows.map do |note|
          note.transform_keys!(&:to_sym)
          note[:score] = map.fetch(note[:id], 0.0)
          note
        end
        .sort_by { |note| -note[:score] }
        .take(limit)
        .map { |note| Notes.present_note(note, max_content_length) }
      end
    end
  end
end
