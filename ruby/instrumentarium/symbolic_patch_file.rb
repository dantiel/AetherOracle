# frozen_string_literal: true

require_relative 'hermetic_execution_domain'
require_relative 'hermetic_symbolic_analysis'
require_relative '../argonaut/argonaut'
require 'open3'
require 'json'

# SymbolicPatchFile — streamlined AST-GREP code transformation.
# Six operations: search, apply, transform_method, transform_class,
# document_method, find_and_replace.
module SymbolicPatchFile
  extend self

  # Read-only semantic search using AST-GREP — no modifications.
  # @param path  [String] File path or glob pattern (e.g. "Support/**/*.rb")
  # @param pattern [String] AST-GREP pattern to search for
  # @param lang [String, nil] Language hint (auto-detected if nil)
  # @return [Hash] { success:, matches: [{file:, line:, column:, text:}] }
  def search(path, pattern, lang: nil)
    glob = Dir.glob(File.join(Dir.pwd, path))
              .reject { |f| File.directory?(f) || f.include?('.git/') }
              .map { |f| Pathname.new(f).relative_path_from(Argonaut.project_root).to_s }

    return { success: false, error: "No files matched: #{path}" } if glob.empty?

    matches = glob.flat_map do |file|
      full = File.join(Argonaut.project_root, file)
      l = lang || HermeticSymbolicAnalysis.detect_language(file)
      cmd = ['ast-grep', 'run', '--pattern', pattern, '--lang', l, '--json', full]
      stdout, _, status = Open3.capture3(*cmd)
      next [] unless status.success? && !stdout.strip.empty?

      JSON.parse(stdout).map do |m|
        { file: file, line: m.dig('range', 'start', 'line') || m['line'],
          column: m.dig('range', 'start', 'column'),
          text: m['text']&.strip }.compact
      end
    rescue JSON::ParserError
      []
    end

    { success: true, matches: matches }
  rescue StandardError => e
    { success: false, error: e.message }
  end

  # Apply a pattern→rewrite transformation via ast-grep.
  def apply(file_path, search_pattern, replace_pattern, lang: nil)
    HermeticExecutionDomain.execute do
      absolute = resolve_path(file_path)
      return { success: false, error: "File not found: #{absolute}" } unless File.exist?(absolute)

      lang ||= HermeticSymbolicAnalysis.detect_language(absolute)

      run_ast_grep_rewrite(absolute, search_pattern, replace_pattern, lang: lang)
    end
  end

  # Rename a method.
  def transform_method(file_path, method_name, new_method_name: nil)
    return { success: false, error: 'new_method_name required' } unless new_method_name

    apply(file_path, "def #{method_name}", "def #{new_method_name}")
  end

  # Rename a class.
  def transform_class(file_path, class_name, new_class_name: nil)
    return { success: false, error: 'new_class_name required' } unless new_class_name

    apply(file_path, "class #{class_name}", "class #{new_class_name}")
  end

  # Prepend a doc-comment above a method definition.
  def document_method(file_path, method_name, documentation)
    formatted = "# #{documentation}"
    apply(file_path, "def #{method_name}", "#{formatted}\ndef #{method_name}")
  end

  # Exact text find-and-replace via ast-grep.
  def find_and_replace(file_path, search_text, replace_text)
    apply(file_path, search_text, replace_text)
  end

  # ── private helpers ────────────────────────────────────────────

  private

  def resolve_path(file_path)
    file_path.start_with?('/') ? file_path : File.join(Dir.pwd, file_path)
  end

  # Convert a project-absolute path to ast-grep-relative (from Support/).
  def ast_grep_relative(absolute)
    Pathname.new(absolute).relative_path_from(Pathname.new(Dir.pwd)).to_s
  end

  def run_ast_grep_rewrite(absolute, search_pattern, replace_pattern, lang:)
    relative = ast_grep_relative(absolute)
    base = ['ast-grep', 'run', '--pattern', search_pattern, '--lang', lang.to_s]

    # Phase 1: capture what would change (JSON preview)
    json_cmd = (base + ['--json', relative, '2>/dev/null']).join(' ')
    json_out = `#{json_cmd}`
    return { success: false, error: 'ast-grep preview failed' } unless $?.success?

    preview = HermeticSymbolicAnalysis.parse_ast_grep_output(json_out)

    # Phase 2: apply changes
    apply_args = base + ['--rewrite', replace_pattern, '--update-all', relative]
    apply_stdout, apply_stderr, apply_status = Open3.capture3(*apply_args)

    if apply_status.success?
      { success: true, result: preview, applied: true }
    else
      { success: false, error: apply_stderr, applied: false }
    end
  end
end