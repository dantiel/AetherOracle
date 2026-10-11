# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'set'

class Mnemosyne
  # Import — the general Mnemosyne import bridge.
  #
  # Pulls *selected* knowledge from a foreign memory database (`.tm-ai/memory.db`,
  # `.aether/mnemosyne.db`, or any explicit path) into the *current* context's
  # Mnemosyne. This is a copy-with-provenance, not a link: unlike
  # `Notes.link_note`, the imported rows live fully in this context.
  #
  # Two deliberate properties:
  #   * Schema-drift tolerance — older DBs lack `context` / `source_note_id`;
  #     the importer detects the live columns and only writes what exists.
  #   * Idempotence — exact-content dedup (notes) and glyph+summary dedup
  #     (companions); re-running imports nothing twice.
  class Import
    class << self
      def project_root
        File.expand_path(ENV['AETHER_PROJECT_ROOT'] || Dir.pwd)
      end

      # Discover candidate memory databases near the project root. The UI can
      # present these as source choices; an explicit path is always also fine.
      def sources(root = project_root)
        [
          [File.join(root, '.tm-ai', 'memory.db'), 'TextMate plugin'],
          [File.join(root, '.aether', 'mnemosyne.db'), 'AetherCodex editor'],
        ].map do |path, name|
          {
            path: path,
            name: name,
            exists: File.exist?(path),
            notes_count: File.exist?(path) ? count_table(path, 'project_notes') : 0,
            companion_count: File.exist?(path) ? count_table(path, 'companion_state') : 0
          }
        end
      end

      # Read-only preview of a foreign DB's notes (for a picker UI).
      #   path:  absolute source path
      #   query: free-text filter across content/tags/links
      #   tag:   exact tag-substring filter
      #   limit: max rows (default 50)
      def list(path:, query: nil, tag: nil, limit: 50)
        src = File.expand_path(path)
        raise "Source memory not found: #{src}" unless File.exist?(src)

        db = open(src)
        begin
          cols = columns(db, 'project_notes')
          select = %w[id content tags links facet created_at updated_at].select { |c| cols.include?(c) }
          where = []
          binds = []
          if tag && !tag.to_s.strip.empty?
            where << 'tags LIKE ?'
            binds << "%#{tag}%"
          end
          if query && !query.to_s.strip.empty?
            query.to_s.split(/\s+/).each do |kw|
              where << '(content LIKE ? OR tags LIKE ? OR links LIKE ?)'
              binds.concat(["%#{kw}%", "%#{kw}%", "%#{kw}%"])
            end
          end
          sql = "SELECT #{select.join(', ')} FROM project_notes"
          sql << " WHERE #{where.join(' AND ')}" unless where.empty?
          sql << ' ORDER BY id DESC LIMIT ?'
          binds << limit.to_i
          db.execute(sql, binds).map { |r| r.transform_keys(&:to_sym) }
        ensure
          db.close
        end
      end

      # Selectively import knowledge from a foreign DB into the current context.
      #   path:               absolute source path
      #   ids:                explicit note ids (takes precedence over query/tag)
      #   query:              filter notes by content/tags/links
      #   tag:                filter notes by exact tag substring
      #   include_companions: also import companion_state rows (default true)
      #   label:              provenance label stamped into `context`
      #                       (default: the source's dir/name, e.g. ".tm-ai/memory.db")
      # Returns { project_notes:, companion_state: } counts.
      def import(path:, ids: [], query: nil, tag: nil, include_companions: true, label: nil)
        src = File.expand_path(path)
        raise "Source memory not found: #{src}" unless File.exist?(src)

        source = open(src)
        target = Mnemosyne.db
        label ||= File.join(File.basename(File.dirname(src)), File.basename(src))

        notes_imported = import_project_notes(source, target, ids: ids, query: query, tag: tag, label: label)
        companions_imported = if include_companions
                                import_companion_state(source, target)
                              else
                                0
                              end

        source.close
        { project_notes: notes_imported, companion_state: companions_imported }
      end

      private

      def open(path)
        db = SQLite3::Database.new(path)
        db.results_as_hash = true
        db.busy_timeout = 10_000
        db
      end

      def columns(db, table)
        db.execute("PRAGMA table_info(#{table})").map { |r| r['name'] }.to_set
      end

      def count_table(path, table)
        db = open(path)
        begin
          db.execute("SELECT COUNT(*) AS c FROM #{table}").first['c'].to_i
        rescue SQLite3::SQLException
          0
        ensure
          db.close
        end
      end

      def existing_note_contents(db)
        db.execute('SELECT content FROM project_notes').map { |r| r['content'] }.compact.to_set
      end

      def existing_companion_keys(db)
        db.execute('SELECT glyph, summary FROM companion_state')
          .map { |r| [r['glyph'], r['summary']] }.to_set
      end

      # Build the SELECT/INSERT column lists that both exist in source and target,
      # so a v7 source (no context/source_note_id) imports cleanly into a v10
      # target and vice-versa. `created_at`/`updated_at`/`facet` are the durable
      # knowledge identity; provenance (`context`/`source_note_id`) is stamped
      # when the target can hold it.
      def note_columns(source_db, target_db)
        src_cols = columns(source_db, 'project_notes')
        tgt_cols = columns(target_db, 'project_notes')
        # Identity columns always copied when present on both sides.
        shared = %w[links content tags facet created_at updated_at].select do |c|
          src_cols.include?(c) && tgt_cols.include?(c)
        end
        { identity: shared, has_context: tgt_cols.include?('context') && tgt_cols.include?('source_note_id') }
      end

      def import_project_notes(source, target, ids:, query:, tag:, label:)
        plan = note_columns(source, target)
        existing = existing_note_contents(target)

        where = []
        binds = []
        ids = Array(ids).map(&:to_i).reject(&:zero?)
        unless ids.empty?
          where << "id IN (#{(['?'] * ids.size).join(', ')})"
          binds.concat(ids)
        else
          if tag && !tag.to_s.strip.empty?
            where << 'tags LIKE ?'
            binds << "%#{tag}%"
          end
          if query && !query.to_s.strip.empty?
            query.to_s.split(/\s+/).each do |kw|
              where << '(content LIKE ? OR tags LIKE ? OR links LIKE ?)'
              binds.concat(["%#{kw}%", "%#{kw}%", "%#{kw}%"])
            end
          end
        end

        select = %w[id] + plan[:identity]
        sql = "SELECT #{select.join(', ')} FROM project_notes"
        sql << " WHERE #{where.join(' AND ')}" unless where.empty?
        sql << ' ORDER BY id ASC'
        rows = source.execute(sql, binds)

        imported = 0
        target.transaction do
          rows.each do |r|
            content = r['content']
            next if content && existing.include?(content)

            cols = plan[:identity]
            vals = cols.map { |c| r[c] }
            if plan[:has_context]
              cols += %w[context source_note_id]
              vals += [label, r['id'].to_i]
            end
            target.execute(
              "INSERT INTO project_notes (#{cols.join(', ')}) VALUES (#{(['?'] * cols.size).join(', ')})",
              vals
            )
            existing << content if content
            imported += 1
          end
        end
        imported
      end

      def import_companion_state(source, target)
        existing = existing_companion_keys(target)
        src_cols = columns(source, 'companion_state')
        tgt_cols = columns(target, 'companion_state')
        shared = %w[glyph summary tags score domain_model created_at].select do |c|
          src_cols.include?(c) && tgt_cols.include?(c)
        end

        rows = source.execute("SELECT #{shared.join(', ')} FROM companion_state ORDER BY id ASC")
        imported = 0
        target.transaction do
          rows.each do |r|
            key = [r['glyph'], r['summary']]
            next if existing.include?(key)

            target.execute(
              "INSERT INTO companion_state (#{shared.join(', ')}) VALUES (#{(['?'] * shared.size).join(', ')})",
              shared.map { |c| r[c] }
            )
            existing << key
            imported += 1
          end
        end
        imported
      end
    end
  end
end
