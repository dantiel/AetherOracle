# frozen_string_literal: true

# ── ÆtherInstrumenta — project-context instruments ──
#
# Every `*.rb` file inside `<project>/.aether/` is loaded once at brain boot,
# after the built-in instrumentarium. A file may register additional tools via
# the same top-level `instrument` DSL that ruby/instrumentarium/instrumenta.rb
# itself uses:
#
#     # .aether/unreal_instrumenta.rb
#     instrument :ue_build,
#                description: "Build the Unreal project via UBT.",
#                params:     { target: { type: String, required: true },
#                              config: { type: String, default: 'Development' } },
#                timeout:    900,
#                returns:    { status: String, log: String } do |target:, config:|
#       out = `"#{target}" -build -config=#{config} 2>&1`
#       { status: $?.success? ? 'ok' : 'fail', log: out }
#     end
#
# Loading happens once per process: edits require a daemon restart (no
# hot-reload). Files load in lexical order; a failing file is isolated
# (reported, never fatal) so one bad instrument cannot take down the brain.
#
# This is a code-execution boundary by design: the file lives in the project's
# own `.aether/` data directory and is authored by the project owner — the same
# trust the agent already extends to the project's own sources.
module AetherInstrumenta
  EXTENSION = '*.rb'
  DIRECTORY = '.aether'

  module_function

  def directory(root = CONFIG.project_root)
    File.join(root, DIRECTORY)
  end

  def discover(root = CONFIG.project_root)
    dir = directory(root)
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, EXTENSION)).sort
  end

  # Load every discovered instrumenta file. Returns a boot report:
  #   { files: [basename…], added: [{name:, file:}…], failed: [{file:, error:}…] }
  def load!(root = CONFIG.project_root)
    files  = discover(root)
    added  = []
    failed = []

    files.each do |file|
      before = Instrumenta::PRIMA_MATERIA.tools.keys
      load file
      (Instrumenta::PRIMA_MATERIA.tools.keys - before).each do |name|
        added << { name: name.to_s, file: File.basename(file) }
      end
    rescue SyntaxError, StandardError => e
      failed << { file: File.basename(file), error: e.message }
    end

    { files: files.map { |f| File.basename(f) }, added: added, failed: failed }
  end

  # Boot entry: load project instruments and announce the result to the log.
  # Silent when no `.aether/*.rb` files exist (the common case).
  def boot!(root = CONFIG.project_root)
    report = load!(root)
    return report if report[:files].empty?

    puts "[AETHER-INSTRUMENTA] #{report[:added].size} instrument(s) from #{report[:files].size} file(s) in #{directory(root)}"
    report[:added].each  { |a| puts "[AETHER-INSTRUMENTA] + #{a[:name]} (#{a[:file]})" }
    report[:failed].each { |f| puts "[AETHER-INSTRUMENTA] ✗ #{f[:file]}: #{f[:error]}" }
    report
  end
end
