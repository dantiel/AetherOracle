# frozen_string_literal: true

require_relative '../argonaut/aether_scopes_hierarchical'

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
      # complete file map to resolve cross-references).
      def sound!(root = project_root)
        Mnemosyne.db.transaction do
          wipe!
          files = source_files(root)
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
        { files: source_files(root).size, nodes: count_nodes, edges: count_edges }
      end

      def wipe!
        Mnemosyne.db.execute('DELETE FROM corpus_nodes')
        Mnemosyne.db.execute('DELETE FROM corpus_edges')
        Mnemosyne.db.execute("DELETE FROM memory_tokens WHERE unit_type = 'corpus_node'")
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