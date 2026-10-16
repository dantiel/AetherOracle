# frozen_string_literal: true

require_relative '../argonaut/aether_scopes_hierarchical'
require 'open3'

class Mnemosyne
  # Corpus -- the project-native graph (Stufe 0 of the ladder). An Argonaut
  # sounding walks the repository and extracts the code's own structure --
  # files and symbols as corpus_nodes, imports/nesting/defines as
  # corpus_edges -- then indexes every node into the polymorphic
  # memory_tokens substrate (unit_type 'corpus_node'). This is Mnemosyne base
  # coverage: the code itself is recallable before the first note is ever
  # minted. The scanner is idempotent; the graph is derived state, rebuilt
  # from a fresh sounding.
  class Corpus
    SCAN_EXTENSIONS = %w[
      .rb .js .jsx .mjs .cjs .ts .tsx .mts .cts .coffee .litcoffee .py .pyw
      .c .h .cpp .hpp .hh .hxx .cc .cxx .swift .m .mm .css .scss .sass .less
      .html .htm .md .markdown .txt .text .json .yml .yaml .gemspec .rake .sh
      .bash .zsh .fish .go .rs .java .kt .kts .cs .php .sql .toml .xml .svg
      .xhtml .ex .exs .lua .mk .dockerfile
    ].freeze

    # Extensionless build/config files still worth sounding.
    BUILD_FILENAMES = %w[makefile gnumakefile dockerfile containerfile].freeze

    SKIP_DIRS = %w[
      .git .hg .svn vendor_bundle .vendor_bundle .vendor vendored node_modules
      .tm-ai .aether tmp log coverage dist build .bundle .sass-cache
    ].freeze

    class << self
      # Repo-relative source paths, normalized to forward slashes, skipping
      # vendor/hidden/build directories.
      def source_files(root = project_root)
        root = File.expand_path(root)
        prefix = root + File::SEPARATOR
        files = []
        Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).each do |abs|
          next if File.directory?(abs)

          rel = abs.delete_prefix(prefix).tr(File::SEPARATOR, '/')
          next if rel.split('/').any? { |seg| SKIP_DIRS.include?(seg) }

          ext = File.extname(abs).downcase
          next unless SCAN_EXTENSIONS.include?(ext) || BUILD_FILENAMES.include?(File.basename(abs).downcase)

          files << rel
        end
        files.sort
      end

      def project_root
        Argonaut.project_root
      end

      # Full idempotent rescan: wipe graph + corpus tokens, sound the repo
      # (pass 1: files + symbols), then wire imports (pass 2: needs the
      # complete file map to resolve cross-references). Afterwards the
      # delta memory (corpus_sightings) is re-seeded and the cartographer
      # weaves the fresh map into Mnemosyne (Atlas, config-gated).
      def sound!(root = project_root)
        files = source_files(root)
        Mnemosyne.db.transaction do
          wipe!
          pending = {}
          files.each do |rel|
            file_id, imports = index_file(rel, root)
            pending[file_id] = { rel: rel, imports: imports } if file_id
          end
          file_by_path = file_index
          pending.each do |file_id, info|
            info[:imports].each do |imp|
              target = resolve_import(imp, info[:rel], file_by_path)
              insert_edge(file_id, target, 'imports', imp[:meta])
            end
          end
        end
        files.each { |rel| record_sighting(rel, fingerprint(rel, root)) }
        woven = defined?(Atlas) ? Mnemosyne.atlas_weave!(kind: :sound) : nil
        { files: files.size, nodes: count_nodes, edges: count_edges, maps: woven }
      end

      def wipe!
        Mnemosyne.db.execute('DELETE FROM corpus_nodes')
        Mnemosyne.db.execute('DELETE FROM corpus_edges')
        Mnemosyne.db.execute("DELETE FROM memory_tokens WHERE unit_type = 'corpus_node'")
      end

      # -- Delta memory (corpus_sightings): the cartographer remembers
      # every file's fingerprint (mtime + size) so the incremental sync!
      # rite only re-sounds what actually changed. --

      def fingerprint(rel, root = project_root)
        st = File.stat(File.join(root, rel))
        "#{st.mtime.to_f.round(3)}:#{st.size}"
      rescue StandardError
        nil
      end

      def record_sighting(rel, fp)
        Mnemosyne.db.execute(<<~SQL, [rel, fp])
          INSERT OR REPLACE INTO corpus_sightings (path, fingerprint, indexed_at)
          VALUES (?, ?, CURRENT_TIMESTAMP)
        SQL
      end

      def remove_sighting(rel)
        Mnemosyne.db.execute('DELETE FROM corpus_sightings WHERE path = ?', [rel])
      end

      def sighting_map
        Mnemosyne.db.execute('SELECT path, fingerprint FROM corpus_sightings')
                  .each_with_object({}) { |r, h| h[r['path']] = r['fingerprint'] }
      end

      def sighting_count
        Mnemosyne.db.execute('SELECT COUNT(*) AS c FROM corpus_sightings').first['c'].to_i
      end

      # Excise one file's nodes, edges and substrate tokens (changed/deleted).
      def remove_file_nodes(rel)
        ids = Mnemosyne.db.execute('SELECT id FROM corpus_nodes WHERE path = ?', [rel]).map { |r| r['id'] }
        return 0 if ids.empty?

        ph = (['?'] * ids.size).join(',')
        Mnemosyne.db.execute("DELETE FROM corpus_edges WHERE source_id IN (#{ph}) OR target_id IN (#{ph})", ids + ids)
        Mnemosyne.db.execute("DELETE FROM corpus_nodes WHERE id IN (#{ph})", ids)
        ids.each { |id| Vectors.unindex_unit('corpus_node', id) if defined?(Vectors) }
        ids.size
      end

      # Incremental rite: compare the repo against the delta memory,
      # re-sound only added/changed files, excise deleted ones, then let
      # the cartographer weave the delta into the cascade. Falls back to
      # a full sounding when the graph or the sightings are empty.
      def cartography
        CONFIG.respond_to?(:cartography) ? CONFIG.cartography : {}
      end

      def meta_get(key)
        row = Mnemosyne.db.execute('SELECT value FROM corpus_meta WHERE key = ?', [key]).first
        row && (row.is_a?(Hash) ? row['value'] : row[0])
      end

      def meta_set(key, value)
        Mnemosyne.db.execute(
          'INSERT INTO corpus_meta (key, value) VALUES (?, ?) ' \
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, value]
        )
        value
      end

      # Git-assisted delta capture: `git status --porcelain` lists staged and
      # unstaged changes that fingerprint collisions (same size + same mtime)
      # would miss. Used by sync! as a force-set; safe under concurrency.
      def git_changed_paths(root = project_root)
        out, _err, status = Open3.capture3('git', 'status', '--porcelain', chdir: root)
        return [] unless status.success?

        out.lines.filter_map do |line|
          code = line[0, 2]
          next if code.strip.empty?

          path = line[3..].to_s.split(' -> ').last.to_s.strip
          path.empty? ? nil : path.tr("\\", "/")
        end
      rescue StandardError
        []
      end

      # Auto-memory for agent edits: re-sight a single touched path into the
      # corpus and weave the delta fragments (Stufe-2 glow). Hooked by the
      # write tools (create_file/patch_file/rename_file) via the central
      # handle. Config-gated: cartography.observe_edits.
      def observe!(path, root = project_root)
        return { observed: false, reason: 'disabled' } unless cartography[:observe_edits]

        abs = File.expand_path(path)
        root_abs = File.expand_path(root)
        rel = abs.delete_prefix(root_abs + File::SEPARATOR).tr("\\", "/")
        return { observed: false, reason: 'outside project', path: abs } if abs == rel || rel.start_with?('..')

        report = sync!(root, force: [rel])
        { observed: true, path: rel, report: report }
      rescue StandardError => e
        { observed: false, error: e.message }
      end

      def sync!(root = project_root, force: [])
        return sound!(root) if count_nodes.zero? || sighting_count.zero?

        files = source_files(root)
        known = sighting_map
        started_at = Time.now
        git_paths = cartography[:git_track] ? git_changed_paths(root) : []
        report = { added: [], changed: [], removed: [], unchanged: 0, files: files.size }
        files.each do |rel|
          fp = fingerprint(rel, root)
          if !known.key?(rel)
            report[:added] << rel
          elsif known[rel] != fp || force.include?(rel)
            report[:changed] << rel
          else
            report[:unchanged] += 1
          end
        end
        report[:removed] = known.keys - files
        # Git union: fingerprints only see mtime+size; git sees content changes
        # invisible to them (same-size same-second edits, external tools,
        # concurrent workers touching the tree). Force re-sound those paths.
        git_paths.each do |gp|
          rel = gp.tr("\\", "/")
          next unless files.include?(rel)
          next if report[:added].include?(rel) || report[:changed].include?(rel)

          report[:changed] << rel
        end

        Mnemosyne.db.transaction do
          reindexed = {}
          (report[:added] + report[:changed]).each do |rel|
            remove_file_nodes(rel)
            file_id, imports = index_file(rel, root)
            reindexed[file_id] = { rel: rel, imports: imports } if file_id
            record_sighting(rel, fingerprint(rel, root))
          end
          report[:removed].each do |rel|
            remove_file_nodes(rel)
            remove_sighting(rel)
          end
          file_by_path = file_index
          reindexed.each do |file_id, info|
            info[:imports].each do |imp|
              target = resolve_import(imp, info[:rel], file_by_path)
              insert_edge(file_id, target, 'imports', imp[:meta])
            end
          end
        end

        describe = lambda do |rels|
          rels.map do |rel|
            symbols = Mnemosyne.db.execute(
              "SELECT COUNT(*) AS c FROM corpus_nodes WHERE path = ? AND kind = 'symbol'", [rel]
            ).first['c'].to_i
            language = Mnemosyne.db.execute(
              "SELECT language FROM corpus_nodes WHERE path = ? AND kind = 'file' LIMIT 1", [rel]
            ).first&.[]('language').to_s
            { rel: rel, symbols: symbols, language: language }
          end
        end
        report[:added] = describe.call(report[:added])
        report[:changed] = describe.call(report[:changed])
        report[:removed].map! { |rel| { rel: rel } }
        woven = defined?(Atlas) ? Mnemosyne.atlas_weave!(kind: :sync, report: report) : nil
        meta_set('last_sync_at', started_at.utc.iso8601(3))
        report.merge(fragments: woven, git: git_paths.size, synced_at: meta_get('last_sync_at'))
      end

      def index_file(rel, root = project_root)
        full = File.join(root, rel)
        return [nil, []] unless File.readable?(full)

        overview = AetherScopesHierarchical.structural_overview(root, rel)
        language = overview[:language]
        file_id = insert_node(
          kind: 'file',
          path: rel,
          language: language,
          name: File.basename(rel),
          content: "#{File.basename(rel)} #{rel}"
        )

        symbol_index = {}
        overview[:hierarchy].each do |item|
          register_symbol(item, rel, language, file_id, file_id, symbol_index)
        end

        # Wire intra-file variable references: `$primary: $brand` becomes an
        # edge from the `$primary` symbol node to the `$brand` symbol node.
        (overview[:references] || []).each do |ref|
          source_id = symbol_index[ref[:source]]
          target_id = symbol_index[ref[:target]]
          next unless source_id && target_id

          insert_edge(source_id, target_id, 'references', "#{ref[:source]} -> #{ref[:target]}")
        end

        imports = overview[:imports].map do |imp|
          { target: imp[:target], meta: "#{imp[:type]} #{imp[:target]}" }
        end

        [file_id, imports]
      rescue StandardError
        [nil, []]
      end

      def register_symbol(item, path, language, file_id, parent_id, symbol_index = {})
        id = insert_node(
          kind: 'symbol',
          path: path,
          language: language,
          name: item[:name],
          qualified_name: item[:qualified_name],
          symbol_type: item[:type],
          parent_name: item[:parent_name],
          parent_type: item[:parent_type],
          line: item[:line],
          end_line: item[:end_line],
          indent: item[:indent],
          content: "#{item[:name]} #{item[:qualified_name]} #{item[:type]}"
        )
        symbol_index[item[:name]] = id
        insert_edge(file_id, id, 'defines', item[:type])
        insert_edge(parent_id, id, 'contains') if parent_id
        (item[:children] || []).each do |child|
          register_symbol(child, path, language, file_id, id, symbol_index)
        end
        id
      end

      def insert_node(kind:, path:, language:, name:, content:, qualified_name: nil,
                      symbol_type: nil, parent_name: nil, parent_type: nil,
                      line: nil, end_line: nil, indent: nil)
        Mnemosyne.db.execute <<~SQL, [kind.to_s, path.to_s, language&.to_s, name.to_s, qualified_name&.to_s, symbol_type&.to_s, parent_name&.to_s, parent_type&.to_s, line, end_line, indent, content.to_s]
          INSERT INTO corpus_nodes
            (kind, path, language, name, qualified_name, symbol_type, parent_name, parent_type, line, end_line, indent, content, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        SQL
        id = Mnemosyne.db.last_insert_row_id
        index_node(id, kind, symbol_type, language, path, content)
        id
      end

      # Base coverage: every node becomes a term vector in the polymorphic
      # substrate. tags carry the semantic anchors (corpus / file|symbol /
      # symbol_type / language) so a free-text query resonates with them.
      def index_node(id, kind, symbol_type, language, path, content)
        return unless defined?(Vectors)

        tags = ['corpus', kind.to_s, symbol_type, language.to_s].reject { |t| t.nil? || t.empty? }
        Vectors.index_unit('corpus_node', id, content, tags: tags, path: path)
      end

      def insert_edge(source_id, target_id, kind, meta = nil)
        return if source_id.nil?

        Mnemosyne.db.execute(
          'INSERT INTO corpus_edges (source_id, target_id, kind, meta, created_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)',
          [source_id, target_id, kind.to_s, meta&.to_s]
        )
      end

      # Best-effort import resolution: map a raw import target to a file-node id.
      def resolve_import(imp, importer_rel, file_by_path)
        import_candidates(imp[:target].to_s, importer_rel).each do |rel|
          norm = normalize_rel(rel)
          return file_by_path[norm] if file_by_path.key?(norm)
        end
        nil
      end

      def import_candidates(target, importer_rel)
        clean = target.sub(%r{^\./}, '').sub(%r{^/}, '')
        dir = File.dirname(importer_rel)
        dir = '.' if dir == '.'
        exts = ['', '.rb', '.js', '.ts', '.py', '.json', '.coffee', '.html', '.css']
        cands = []
        if clean.start_with?('..')
          cands << File.join(dir, clean)
          if File.extname(clean).empty?
            exts.each { |e| cands << File.join(dir, clean + e) }
          end
        else
          cands << clean
          if File.extname(clean).empty?
            exts.each { |e| cands << "#{clean}#{e}" }
          end
          cands << File.join(dir, clean)
          if File.extname(clean).empty?
            exts.each { |e| cands << File.join(dir, clean + e) }
          end
          cands << File.join('lib', clean)
          cands << File.join('ruby', clean)
        end
        cands.uniq
      end

      def normalize_rel(rel)
        parts = []
        rel.gsub('\\', '/').split('/').each do |seg|
          case seg
          when '.', '' then next
          when '..' then parts.pop
          else parts << seg
          end
        end
        parts.join('/')
      end

      # Area view for the cartographer: top-level directories with file and
      # symbol counts plus a handful of sample files per area.
      def map_groups(limit_samples: 6)
        rows = Mnemosyne.db.execute(
          "SELECT path FROM corpus_nodes WHERE kind = 'file' ORDER BY path"
        )
        groups = Hash.new { |h, k| h[k] = { files: [], symbols: 0 } }
        rows.each do |r|
          seg = r['path'].split('/')
          area = seg.size > 1 ? seg[0] : '(root)'
          groups[area][:files] << r['path']
        end
        groups.each do |area, g|
          g[:symbols] = if area == '(root)'
                          Mnemosyne.db.execute(
                            "SELECT COUNT(*) AS c FROM corpus_nodes WHERE kind = 'symbol' AND path NOT LIKE '%/%'"
                          ).first['c'].to_i
                        else
                          Mnemosyne.db.execute(
                            "SELECT COUNT(*) AS c FROM corpus_nodes WHERE kind = 'symbol' AND path LIKE ?",
                            ["#{area}/%"]
                          ).first['c'].to_i
                        end
          g[:samples] = g[:files].first(limit_samples)
        end
        groups.sort_by { |area, g| -g[:files].size }.to_h
      end

      def file_index
        rows = Mnemosyne.db.execute("SELECT id, path FROM corpus_nodes WHERE kind = 'file'")
        rows.each_with_object({}) { |r, h| h[r['path']] = r['id'] }
      end

      def count_nodes
        Mnemosyne.db.execute('SELECT COUNT(*) AS c FROM corpus_nodes').first['c'].to_i
      end

      def count_edges
        Mnemosyne.db.execute('SELECT COUNT(*) AS c FROM corpus_edges').first['c'].to_i
      end
    end
  end
end
