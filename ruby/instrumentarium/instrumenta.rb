# frozen_string_literal: true

# frozen_string_literal: true
require_relative '../magnum_opus/magnum_opus_engine'
require_relative '../argonaut/argonaut'
require_relative '../mnemosyne/mnemosyne'
require_relative '../oracle/oracle'
require_relative 'horologium_aeternum'
require_relative 'prima_materia'
require_relative 'verbum'
require_relative '../instrumentarium/scriptorium'
require_relative '../argonaut/temp_create_file'
require_relative 'symbolic_patch_file'
require_relative 'captura_visus'
require_relative 'nuntius'
require_relative 'companion_programs'




# Instrumenta: The Atlantean tool collection for precise code plane operations.
# Current-state focused tool schema optimized for efficient AI execution.
class Instrumenta
  PRIMA_MATERIA = PrimaMateria.new


  def initialize
    @prima_materia = PRIMA_MATERIA
  end


  class << self
    def instrumenta_schema = PRIMA_MATERIA.instrumenta_schema
    def schema = PRIMA_MATERIA.schema
    def tools = PRIMA_MATERIA.tools
    def handle(...) = PRIMA_MATERIA.handle(...)


    def reject(*tool_names)
      filtered_prima = PRIMA_MATERIA.reject(*tool_names)
      # Return a new Instrumenta instance that wraps the filtered PrimaMateria
      filtered_instrumenta = Instrumenta.new
      filtered_instrumenta.instance_variable_set :@prima_materia, filtered_prima
      filtered_instrumenta
    end

    def select(*tool_names)
      filtered_prima = PRIMA_MATERIA.select(*tool_names)
      # Return a new Instrumenta instance that wraps the filtered PrimaMateria
      filtered_instrumenta = Instrumenta.new
      filtered_instrumenta.instance_variable_set :@prima_materia, filtered_prima
      filtered_instrumenta
    end
  end


  # Delegate all methods to the wrapped PrimaMateria instance
  def method_missing(method_name, ...)
    if @prima_materia.respond_to? method_name
      @prima_materia.send(method_name, ...)
    else
      super
    end
  end


  def respond_to_missing?(method_name, include_private = false)
    @prima_materia.respond_to?(method_name) || super
  end
end


def instrument(...) = Instrumenta::PRIMA_MATERIA.add_instrument(...)


# --- Register All Tools ---
instrument :read_file,
           description: <<~DESC,
             Read a file (optionally a line range). Pass `line_numbers: true` to
             prefix each line with its number (e.g. "42: |") for precise targeting.
           DESC
           params: { path:         { type: String, required: true, minLength: 1 },
                     range:        { type:     Array,
                                     required: false,
                                     items:    { type: 'integer', minimum: 0, maximum: 10_000 },
                                     minItems: 2,
                                     maxItems: 2 },
                     line_numbers: { type: 'boolean', required: false } },
           returns: { content: String, error: String } do |path:, range: nil, line_numbers: false|
  raise 'Denied path' if PrimaMateria::DENY_PATHS.any? { |re| re.match? path }

  start_time = Time.now
  uuid = HorologiumAeternum.file_reading path, range
  result = Argonaut.read path, range, line_numbers: line_numbers
  raise result[:error] unless result[:error].nil?

  # Vorfahrtsregeln §6: the context remembers *when* it last read this file.
  HorologiumAeternum.stamp_read path

  bytes_read = result[:content]&.bytesize || 0
  exec_time = (Time.now - start_time).round(3)
  HorologiumAeternum.file_read_complete(path, bytes_read, range, result[:content], uuid:, execution_time: exec_time)
  result
rescue StandardError => e
  suggestions = if File.directory?(File.join(Argonaut.project_root, path))
                  contents = Dir.children(File.join(Argonaut.project_root, path))
                               .map { |n| File.directory?(File.join(Argonaut.project_root, path, n)) ? "#{n}/" : n }
                               .sort_by { |n| n.start_with?('.') ? 1 : 0 }
                  "Directory '#{path}' — contents:\n  #{contents.take(50).join("\n  ")}" \
                  "#{'  …' if contents.size > 50}"
                else
                  all_files = Argonaut.list_project_files
                  similar = all_files.select { |f| similarity(path, f) > 0.4 }
                              .sort_by { |f| -similarity(path, f) }
                              .take(5)
                  if similar.any?
                    "File not found: #{path}\nDid you mean?\n  #{similar.join("\n  ")}"
                  end
                end
  HorologiumAeternum.file_read_fail(path, e.message, range, uuid:)
  { error: [e.message, suggestions].compact.join("\n\n") }
end

private

def similarity(a, b)
  a, b = a.downcase, b.downcase
  pairs_a = a.chars.each_cons(2).to_set
  pairs_b = b.chars.each_cons(2).to_set
  intersection = (pairs_a & pairs_b).size
  union = (pairs_a | pairs_b).size
  union.zero? ? 1.0 : intersection.to_f / union
end

# When reasoning is invoked, tools are excluded to enable advanced reasoning capabilities
instrument :oracle_conjuration,
           description: <<~DESC,
             Invoke advanced reasoning for complex problem-solving. This conjuration provides
             only the final prompt and context to the reasoning model - no tool execution is possible.

             **REQUIRED PREPARATION**: Before invocation, you MUST:
               - Perform comprehensive research using all available tools
               - Gather complete file contents and structural analysis
               - Prepare detailed reasoning plan and context
               - Include all relevant information in the prompt
               - Put explanations and thoughts in the prompt
             #{'  '}
               **CRITICAL**: In reasoning mode, you CANNOT call any tools including oracle_conjuration itself
             #{'  '}
               The reasoning model receives only your prepared prompt and context.
               Previous tool results (such as file reads, overviews, previous conjuration results)
               are automatically passed in the context.
           DESC
           params: { prompt:  { type:        String,
                                required:    true,
                                description: 'The input prompt for reasoning.' },
                     context: { type:        Object,
                                required:    false,
                                description: 'Context object to pass through to oracle' } },
           history_priority: 10,
           timeout: 6600,
           returns: { reasoning: String,
                      content:   String,
                      context:   Object } do |prompt:, context: nil, history: true|
  # Add reasoning flag to context for proper system prompt selection
  context_with_reasoning = context ? context.merge(reasoning: true) : { reasoning: true }

  params = {
    prompt:  prompt,
    context: context_with_reasoning,
    history:
  }
  HorologiumAeternum.oracle_conjuration prompt

  puts "CONJURATION TOOL CONTEXT=#{context.inspect.truncate 200}"

  # For DeepSeek reasoning, we must NOT pass any tools to enable advanced reasoning
  # The reasoning model cannot use tools, so we provide empty tools array
  puts "[CONJURATION][DEBUG]: Starting conjuration with params: #{params.inspect.truncate 200}"
  # For reasoning, we need to pass empty tools object, not nil
  result = Aetherflux.channel_oracle_conjuration params, tools: nil
  puts "[CONJURATION][DEBUG]: Aetherflux result: #{result.inspect.truncate 300}"

  if result[:error]
    puts "[CONJURATION][ERROR]: #{result[:error]}"
    raise result[:error]
  end

  if :success == result[:status] && result[:response]
    reasoning = result[:response][:reasoning]
    answer = result[:response][:answer]

    puts "[CONJURATION][DEBUG]: Success - reasoning: #{reasoning.to_s.truncate 100}, answer: #{answer.to_s.truncate 100}"

    unless reasoning.to_s.empty?
      HorologiumAeternum.oracle_conjuration_revelation 'Oracle Reasoning', reasoning
    end
    
    unless answer.to_s.empty?
      HorologiumAeternum.oracle_conjuration_revelation 'Oracle Answer', answer
    end
  else
    puts "[CONJURATION][DEBUG]: Failed - status: #{result[:status]}, response: #{result[:response].inspect.truncate 200}"
    reasoning = nil
    answer = nil
  end

  { reasoning:, content: answer }
rescue StandardError => e
  { error: "Reasoning failed: #{e.message}" }
end


instrument :run_command,
           description: PrimaMateria.dynamic_run_command_description,
           params: { cmd:     { type: String, required: true },
                     timeout: { type: Integer, default: 30 } },
           timeout: 30_000,
           returns: { ok:          Boolean,
                      exit_status: Integer,
                      result:      String,
                      error:       String } do |cmd:, timeout:|
  # ── Gate: command permission ──────────────────────────────────────────
  # Check wildcard FIRST, directly, before any method delegation
  allowed_commands = PrimaMateria.allowed_commands
  blocked_commands = PrimaMateria.blocked_commands

  # Direct wildcard check — regardless of what PrimaMateria returns
  wildcard_active  = allowed_commands.any? { |re| // == re }
  command_allowed  = wildcard_active || allowed_commands.any? { |re| cmd =~ re }
  command_blocked  = blocked_commands.any? { |re| cmd =~ re }

  if !command_allowed || command_blocked
    $stderr.puts "[AEGIS] run_command blocked: cmd=#{cmd.inspect} wildcard=#{wildcard_active} allowed=#{command_allowed} blocked=#{command_blocked} allow_list=#{allowed_commands.inspect} block_list=#{blocked_commands.inspect}"
    ask_uuid = SecureRandom.uuid
    HorologiumAeternum.send_status('ask_user', {
                                     type: 'confirm',
                                     message: "Blocked command: #{cmd}\nAllow execution?",
                                     options: %w[Allow Block]
                                   }, uuid: ask_uuid)
    result = HorologiumAeternum.await_user_response(ask_uuid)
    raise "🚫 Blocked command: `#{cmd}`" unless result[:response]&.downcase == 'allow'
  end

  uuid = HorologiumAeternum.command_executing cmd
  cmd_start = Time.now
  # Saum §6: Einfrieren der eigenen read-stamps vor dem Befehlsfenster.
  before = HorologiumAeternum.read_stamps_snapshot

  begin
    project_root = Argonaut.project_root
    run_command_env = Dotenv.parse "#{project_root}/.env.run_command", overwrite: true
 
    env_vars = run_command_env.merge({ 'BUNDLE_GEMFILE' => '' })
 
    # Couple the agent's shell to the same filesystem truth as the user's Pythia
    # CLI. When the polymorphic ShellSession exists (the daemon always installs
    # one), route through it so a `cd` persists bidirectionally — the agent's
    # turn-branch and the user's CLI read and write the same cwd.
    if $aether_shell
      shell_result = $aether_shell.run(cmd, env: env_vars, timeout: timeout)
      stdout      = shell_result[:stdout].to_s
      stderr      = shell_result[:stderr].to_s
      exitstatus  = shell_result[:exit_status]
      cwd         = shell_result[:cwd]
    else
      stdout, stderr, status = Verbum.run_command_in_real_time env_vars, cmd,
                                                               chdir: project_root, timeout_seconds: timeout
      exitstatus = status.respond_to?(:exitstatus) ? status.exitstatus : nil
      cwd = project_root
    end
 
    out = (stdout + stderr + "\n(exit #{exitstatus})").strip
    exec_time = (Time.now - cmd_start).round(3)
    HorologiumAeternum.command_completed(cmd, out.length, out, exitstatus, uuid:, execution_time: exec_time, cwd: cwd)

    # Saum §6: Diff nach dem Fenster — hat sich ein bereits gelesener Pfad bewegt?
    drift = HorologiumAeternum.detect_drift before
    unless drift.empty?
      HorologiumAeternum.send_status('peer_drift', {
                                       message: Scriptorium.html("⚠️ 🐺 Drift im Befehlsfenster — #{drift.size} gelesene(r) Pfad(e) bewegt. Neu lesen vor dem nächsten Schnitt."),
                                       drifted: drift
                                     }, uuid:)
    end

    # Use Scriptorium HTML utils for proper escaping
    escaped_out = Scriptorium.escape_html out

    { ok: true, exit_status: exitstatus, result: "Command output: #{escaped_out}", cwd: cwd, peer_drift: drift }
  rescue StandardError => e
    { error: "Command error: #{e.message}" }
  end
end


instrument :create_file,
           description: 'Create (or overwrite) a file with given content.',
           params: { path:      { type: String, required: true },
                     content:   { type: String, required: true },
                     overwrite: { type: Boolean, required: false, default: false } },
           returns: { ok: Boolean, error: String } do |path:, content:, overwrite: false|
  next { error: 'Denied path' } if PrimaMateria::DENY_PATHS.any? { |re| re.match? path }

  bytes = content.bytesize
  uuid = HorologiumAeternum.file_creating path, bytes

  full = File.join Argonaut.project_root, path

  if File.exist?(full) && !overwrite
    HorologiumAeternum.send_status('ask_user', {
                                     type: 'confirm',
                                     message: "File already exists: #{path}\nOverwrite?",
                                     options: %w[Overwrite Cancel]
                                   }, uuid:)
    result = HorologiumAeternum.await_user_response(uuid)
    next { error: "File exists: #{path} (user cancelled)" } unless result[:response]&.downcase == 'overwrite'
  end

  # Vorfahrtsregeln §6: Selbstkontrolle beim Überschreiben eines Bestands.
  if File.exist?(full) && HorologiumAeternum.self_check(path) == :danger
    HorologiumAeternum.send_status('self_control_danger', {
      message: Scriptorium.html("⚠️ Selbstkontrolle: `#{path}` hat sich seit dem letzten Lesen verändert — neu lesen, nicht blind überschreiben."),
      path:    path
    })
    next { error: "Selbstkontrolle: #{path} hat sich seit dem letzten Lesen verändert. Neu lesen, dann überschreiben." }
  end

  Argonaut.write path, content
  HorologiumAeternum.stamp_write(path)
  HorologiumAeternum.file_created(path, bytes, content, uuid:)
  { ok: true }
rescue StandardError => e
  { error: e.message }
end


instrument :rename_file,
           description: 'Rename a file with given content. May also be used to move files.',
           params: { from: { type: String, required: true },
                     to:   { type: String, required: true } },
           returns: { ok: Boolean, error: String } do |from:, to:|
  next { error: 'Denied path' } if [from, to].any? do |p|
    PrimaMateria::DENY_PATHS.any? do |re|
      re.match? p
    end
  end

  # Vorfahrtsregeln §6: Selbstkontrolle vor dem Schnitt.
  if HorologiumAeternum.self_check(from) == :danger
    HorologiumAeternum.send_status('self_control_danger', {
      message: Scriptorium.html("⚠️ Selbstkontrolle: `#{from}` hat sich seit dem letzten Lesen verändert — neu lesen, nicht blind umbenennen."),
      path:    from
    })
    next { error: "Selbstkontrolle: #{from} hat sich seit dem letzten Lesen verändert. Neu lesen, dann umbenennen." }
  end

  uuid = HorologiumAeternum.file_renaming from, to
  Argonaut.rename from, to
  HorologiumAeternum.stamp_write(to)
  HorologiumAeternum.file_renamed(from, to, uuid:)
  { ok: true }
rescue StandardError => e
  { error: e.message }
end


instrument :temp_create_file,
           description: <<~DESC,
             Create a temporary file with automatic context-based cleanup. The file will be
             automatically removed when the oracle context terminates. Supports both system
             temp files and project-relative paths with nested context management. Use this for#{' '}
             local script, and test files for example.
           DESC
           params: { content: { type:        String,
                                required:    true,
                                description: 'The content to write to the temporary file.' },
                     path:    { type:        String,
                                required:    false,
                                description: 'Optional relative path within project (nil for system temp files)' } },
           returns: { path:    String,
                      success: Boolean,
                      error:   String } do |content:, path: nil|
  # Debug: check what parameters are received
  puts "[INSTRUMENTA] temp_create_file called with path: #{path.inspect}"

  result = Argonaut::TempFile.create content, path: path

  puts "[INSTRUMENTA] Argonaut::TempFile.create result: #{result.inspect}"

  if result[:success]
    uuid = HorologiumAeternum.temp_file_created path, content, content.bytesize
    result
  else
    { error: result[:error] }
  end
rescue StandardError => e
  puts "[INSTRUMENTA] Error: #{e.message}"
  { error: "Temporary file creation failed: #{e.message}" }
end


instrument :recall_history,
           description: 'Retrieve notes from Mnemosyne. Without a query just yields last.',
           params: { query: { type: String, required: false },
                     limit: { type: Integer, required: false, default: 3 } },
           returns: { notes: Array, error: String } do |query: '', limit: 7|
  uuid = HorologiumAeternum.memory_searching query, limit
  result = { notes: Mnemosyne.search(query, limit: limit) }
  HorologiumAeternum.memory_found(query, result[:notes]&.length || 0, result[:notes].inspect,
                                  uuid:)
  result
rescue StandardError => e
  puts "[PrimaMateria][ERROR]: #{e.inspect}"
  { error: e }
end


instrument :tell_user,
           description: 'If you wish to inform the user mid-process.',
           params: { message: { type: String, required: true },
                     level:   { type: String, required: false, enum: %w[info warn] } },
           returns: { say: Hash, error: String } do |message:, level: 'info'|
  HorologiumAeternum.info_message message
  sound = level == 'warn' ? 'Basso' : 'Glass'
  Nuntius.deliver(title: 'ÆtherCodex', message: message, sound: sound)
  { say: { level: level, message: message } }
end


instrument :recall_notes,
           description: 'Recall notes from Mnemosyne by tags, content or context. ' \
                        'Uses fuzzy matching with enhanced scoring: content (4x), ' \
                        'tags (3x), links (2x), path matches (+5). Current-state only. ' \
                        'Pass `id` for direct lookup by note ID (useful from file_overview ' \
                        'which returns note counts). Max. content length reduced by higher limit.',
           params: { query: { type: String, required: false },
                     id:    { type: Integer, required: false, description: 'Direct note ID lookup' },
                     limit: { type: Integer, required: false, default: 3 } },
           returns: { notes: Array, error: String } do |query: '', id: nil, limit: 2|
  result = if id
             note = Mnemosyne.get_note(id)
             if note
               { notes: [note] }
             else
               { error: "Note ##{id} not found" }
             end
           else
             { notes: Mnemosyne.recall_notes(query, limit: limit, max_content_length: 1111 / limit) }
           end
  HorologiumAeternum.notes_recalled query, limit, result[:notes] if result[:notes]
  result
rescue StandardError => e
  { error: e.message }
end


instrument :file_overview,
           description: <<~DESC,
             Fetch file information with symbolic parsing. Returns lightweight metadata:
             note count, and note relations of tags to files. Enhanced symbolic analysis shows
             structural view with classes, methods, constants, and navigation hints. Use this in
             combination with read_file range to fetch minimal parts of a file and have an overview
             about its relations. The hermetic overview shows the number of notes per associated file,
             use `recall_notes` to see note content.
           DESC
           params: { path: { type: String, required: true } },
           returns: { metadata: Hash, error: String } do |path:|
  path = Argonaut.relative_path path

  # Use optimized parameters to prevent context bloat
  results = Argonaut.file_overview path: path, max_notes: 3, max_content_length: 333
  raise results[:error] unless results[:error].nil?

  HorologiumAeternum.file_overview path, results

  result = {
    notes_count:        results[:notes_count],
    notes_preview:      results[:notes_preview],
    file_info:          results[:file_info],
    structural_summary: results[:symbolic_overview][:structural_summary],
    symbolic_overview:  results[:symbolic_overview][:symbolic_overview_text],
    tag_cloud:          results[:symbolic_overview][:tag_cloud_text],
    file_cloud:         results[:symbolic_overview][:file_cloud_text],
    hermetic_overview:  results[:hermetic_overview]
  }
  # puts results.inspect
  # puts '==================================================='
  puts result.inspect
  result
rescue StandardError => e
  puts "[PRIMA MATERIA][ERROR]: #{e.inspect}"
  { error: "File overview for #{path} failed: #{e.message || e.error}" }
end


instrument :remember,
           description: <<~DESC,
             Store current-state note: structure, patterns, architecture only.
             Never historical changes or timelines. Links enable path-based
             relevance scoring in recall_notes. Purge outdated notes regularly.
           DESC
           params: { id:      { type: Integer, required: false },
                     content: { type: String, required: true },
                     links:   { type: Array, items: { type: :string }, required: false },
                     tags:    { type: Array, items: { type: :string }, required: false } },
           returns: { ok:    Boolean,
                      error: String } do |content:, id: nil, links: nil, tags: nil|
  # links = if links.is_a? String

  note = { content: content, links: links, tags: tags }
  if id.nil?
    Mnemosyne.create_note(**note)
    uuid = HorologiumAeternum.note_added note
  else
    Mnemosyne.update_note id, **note
    HorologiumAeternum.note_updated(note, uuid:)
  end

  { ok: true }
rescue StandardError => e
  puts "[PrimaMateria][ERROR]: #{e.inspect}"
  { error: e }
end


instrument :remove_note,
           description:  'Remove a note by id.',
           params: { id: { type: Integer, required: true } },
           returns: { ok: Boolean, error: String } do |id:|
  note = Mnemosyne.get_note id
  Mnemosyne.remove_note id
  HorologiumAeternum.note_removed note unless note.nil?
  { ok: true }
end


instrument :metempsychosis,
           description: 'Consult the memory of another task — the transmigration of knowledge ' \
                        'between contexts. Query notes and state from a specific task (by ID), ' \
                        'a remote ÆtherLink context (+from_context+), or the global memory. ' \
                        'Push notes to a remote context with +to_context+. Spawn a task on a ' \
                        'remote context with +create_task_in+. Execute +query+ as a prompt in a ' \
                        'remote context with +invoke_in+ — the peer works with the combined ' \
                        'memories of both contexts and the result is marked as performed via ' \
                        'metempsychosis (+via_metempsychosis+/+source_context+). When ' \
                        '+subscribe+ is true, the ' \
                        'other task\'s context is merged into your Aegis orientation — ' \
                        'the soul moves in, not just visits. Use +unsubscribe+ to release it.',
           params: {
             query:          { type: String, required: true },
             from_task:      { type: Integer, required: false, description: 'Task ID whose memory to consult (nil for global only)' },
             limit:          { type: Integer, required: false, default: 3 },
             subscribe:      { type: Boolean, required: false, default: false, description: 'Merge the other task\'s context into your Aegis orientation' },
             unsubscribe:    { type: Boolean, required: false, default: false, description: 'Remove the other task\'s context from your Aegis orientation' },
             from_context:   { type: String, required: false, description: 'Remote context name — query peer\'s memory via ÆtherLink' },
             to_context:     { type: String, required: false, description: 'Remote context name — push notes into peer\'s memory' },
             create_task_in: { type: String, required: false, description: 'Remote context name — spawn a task on peer' },
             invoke_in:      { type: String, required: false, description: 'Remote context name — execute query as a prompt there (via metempsychosis)' }
           },
           returns: { notes: Array, task_summary: Hash, subscribed: Boolean, invoked_in: String, via_metempsychosis: Boolean, answer: String, error: String } do |query:, from_task: nil, limit: 3, subscribe: false, unsubscribe: false,
                                                                                                  from_context: nil, to_context: nil, create_task_in: nil, invoke_in: nil|
  result = Mnemosyne.metempsychosis(query: query, from_task: from_task, limit: limit,
                                    subscribe: subscribe, unsubscribe: unsubscribe,
                                    from_context: from_context, to_context: to_context,
                                    create_task_in: create_task_in, invoke_in: invoke_in)
  HorologiumAeternum.notes_recalled "metempsychosis: #{query}", limit, result[:notes] if result[:notes]
  result
rescue StandardError => e
  { error: e.message }
end


instrument :patch_file,
           description: <<~DESC,
             Request to apply PRECISE, TARGETED modifications to an existing file by searching
             for specific sections of content and replacing them. This tool is for SURGICAL EDITS
             ONLY - specific changes to existing code.

             You can perform multiple distinct search and replace operations within a single
             `patch_file` call by providing multiple SEARCH/REPLACE blocks in the `diff`
             parameter. This is the preferred way to make several targeted changes efficiently.

             The SEARCH section must exactly match existing content including whitespace and
             indentation.

             If you're not confident in the exact content to search for, use the `read_file` tool
             first to get the exact content.

             When applying the diffs, be extra careful to remember to change any closing brackets
             or other syntax that may be affected by the diff farther down in the file.

             ALWAYS make as many changes in a single 'patch_file' request as possible using
             multiple SEARCH/REPLACE blocks.

             If a patch fails it may be that the line number was too wrong.

             ### Diff Format:
             ```
             <<<<<<< SEARCH
             :start_line: (required) The line number of original content where the search block begins.
             -------
             [exact content to find including whitespace]
             =======
             [new content to replace with]
             >>>>>>> REPLACE
             ```

             ### Example 1: Single Edit
             ```
             <<<<<<< SEARCH
             :start_line:116
             -------
             def calculate_total(items):
                 total = 0
                 for item in items:
                     total += item
                 return total
             =======
             def calculate_total(items):
                 """Calculate total with 10% markup"""
                 return sum(item * 1.1 for item in items)
             >>>>>>> REPLACE
             ```

             ### Example 2: Multiple Edits
             ```
             <<<<<<< SEARCH
             :start_line:10
             -------
             def calculate_total(items):
                 sum = 0
             =======
             def calculate_sum(items):
                 sum = 0
             >>>>>>> REPLACE

             <<<<<<< SEARCH
             :start_line:42
             -------
                 total += item
                 return total
             =======
                 sum += item
                 return sum
             >>>>>>> REPLACE
             ```
           DESC
           params: { path: { type: String, required: true },
                     diff: { type: String, required: true } },
           returns: { ok: Boolean, error: String } do |path:, diff:|
  next { error: 'missing :path or :diff' } unless path && diff

  diff_lines = diff.lines.count

  # Vorfahrtsregeln §6: Selbstkontrolle vor dem Schnitt — der Kontext prüft
  # seinen eigenen Lese-Zeitstempel gegen den mtime des Bestands.
  if HorologiumAeternum.self_check(path) == :danger
    HorologiumAeternum.send_status('self_control_danger', {
      message: Scriptorium.html("⚠️ Selbstkontrolle: `#{path}` hat sich seit dem letzten Lesen verändert — neu lesen, nicht blind schneiden."),
      path:    path
    })
    next { error: "Selbstkontrolle: #{path} hat sich seit dem letzten Lesen verändert. Neu lesen, dann schneiden." }
  end

  uuid = HorologiumAeternum.file_patching path, diff, diff_lines

  raise 'Diff too big' if PrimaMateria::MAX_DIFF < diff.lines.count

  result = Argonaut.patch path, diff
  if result[:ok]
    old_content, new_content = result[:result]
    HorologiumAeternum.stamp_write(path)
    HorologiumAeternum.file_patched(path, old_content, new_content, uuid:)
    { ok: true }
  else
    HorologiumAeternum.file_patched_fail(path, result[:error], diff, uuid:)
    { error: "patch failed: #{result[:error].to_json}" }
  end
rescue StandardError => e
  HorologiumAeternum.file_patched_fail(path, e.message, diff, uuid:)
  { error: "patch failed: #{e.message}" }
end


instrument :undo_patch,
           description: <<~DESC,
             Revert a previous patch_file operation using the undo token.
             Restores the file to its state before the patch was applied.
           DESC
           params: { undo_token: { type: String, required: true, description: 'Token from file_patched event' } },
           returns: { ok: Boolean, path: String, error: String } do |undo_token:|
  
  next { error: 'missing :undo_token' } unless undo_token
  
  result = HorologiumAeternum.undo_patch(undo_token)
  result
end


instrument :aegis,
           description:  <<~DESC,
             Maintain active context from Mnemosyne. Returns scored notes with
             current-state focus. Summary required for orientation refinement.
             Also controls dynamic agent state: thinking level and temperature —
             persisted until explicitly changed.
           DESC
           params: { tags:        { type: Array, required: false, items: { type: 'string' } },
                     summary:     { type:        String,
                                    required:    false,
                                    description: 'Dynamic summary update without altering ' \
                                                 'tags. Required for every invocation.' },
                     temperature: { type:        Number,
                                    required:    false,
                                    description: 'Optional parameter to fine-tune the Aegis ' \
                                                 'state responsiveness.' },
                     thinking:    { type:        String,
                                    required:    false,
                                    enum:        %w[max high normal fast],
                                    description: 'Thinking depth. "max"/"high"=deep reasoning, ' \
                                                 '"normal"=standard (default), ' \
                                                 '"fast"=skip thinking, use fast-model.' },
                     working_dir: { type:        String,
                                    required:    false,
                                    description: 'Set the working directory within the project ' \
                                                 'to scope file listing and memory preferences. ' \
                                                 'Only show files under this path.' } },
           returns: { aegis_notes:       Array,
                      aegis_orientation: Hash,
                      error:             String } do |tags: nil, summary: '', temperature: nil,
                                                      thinking: nil, working_dir: nil|
  Mnemosyne.set_working_dir working_dir if working_dir
  notes = Mnemosyne.unveil_aegis(tags:, summary:, temperature:, thinking:)

  thinking_level = Mnemosyne.aegis[:thinking]
  HorologiumAeternum.aegis_unveiled tags, summary, temperature, thinking_level, notes

  { aegis_notes: notes, aegis_orientation: Mnemosyne.aegis }
rescue StandardError => e
  { error: "Aegis failed: #{e.message}" }
end


instrument :create_task,
           description:  <<~DESC,
             Generate a task for complex prompts with fields for plan and title. During Task
             execution no other history context is given to the AI (you). Make sure that plan is very
             descriptive.
           DESC
           params: { title: { type:        String,
                              required:    true,
                              description: 'The title of the plan.' },
                     plan:  { type:        String,
                              required:    true,
                              description: 'The task execution plan.' },
                     workflow_type: { type:        String,
                                      required:    false,
                                      enum:        %w[full simple analysis debug],
                                      description: 'Workflow shape: full=10 alchemical phases, ' \
                                                   'simple=3, analysis=5, debug=step through all ' \
                                                   'phases without executing any tools.' } },
           returns: { id: Integer, error: String } do |title:, plan:, workflow_type: 'full', quiet: false|
  engine = MagnumOpusEngine.new mnemosyne: Mnemosyne, aetherflux: Aetherflux

  result = engine.create_task title:, plan:, workflow_type: workflow_type, quiet: quiet

  uuid = HorologiumAeternum.task_created(**result)

  result
rescue StandardError => e
  HorologiumAeternum.system_error('Error Creating Task', message: e.message, uuid:)

  { error: e.message }
end


instrument :execute_task,
           description: 'Run the task loop with minimal intervention, updating status and ' \
                        'progress.',
           params: { task_id: { type:        Integer,
                                required:    true,
                                description: 'The ID of the task to execute.' } },
           timeout: 86_400,
           returns: { ok: Boolean, error: String } do |task_id:|
  task = Mnemosyne.get_task task_id
  next { error: 'Task not found' } unless task

  uuid = HorologiumAeternum.task_started(**task)

  engine = MagnumOpusEngine.new mnemosyne: Mnemosyne, aetherflux: Aetherflux
  engine.execute_task task[:id]

  # Compact summary — the full step phases live in the ⚗️ Magnum Opus task
  # runner (polled via task_detail), not as a JSON dump in the chat flow.
  refreshed = Mnemosyne.get_task task_id
  { ok: true, task_id: task_id, status: refreshed&.dig(:status),
    current_step: refreshed&.dig(:current_step) }
rescue StandardError => e
  HorologiumAeternum.system_error('Error Executing Task', message: e.message, uuid:)

  { error: e.message }
end


instrument :update_task,
           description: 'Dynamically refine the task plan during execution.',
           params: { task_id:  { type:        Integer,
                                 required:    true,
                                 description: 'The ID of the task to update.' },
                     new_plan: { type:        String,
                                 required:    true,
                                 description: 'The updated task plan.' } },
           returns: { ok: Boolean, error: String } do |task_id:, new_plan:|
  task = Mnemosyne.update_task task_id, plan: new_plan
  uuid = HorologiumAeternum.task_updated(**task, plan: new_plan)
  { ok: true }
rescue StandardError => e
  HorologiumAeternum.system_error('Error Updating Task', message: e.message, uuid:)
  { error: e.message }
end


instrument :evaluate_task,
           description: 'Check task progress and handle edge cases. Returns comprehensive task information including step results, execution logs, and alchemical progression stages.',
           params: { task_id: { type:        Integer,
                                required:    true,
                                description: 'The ID of the task to evaluate.' } },
           returns: { status:                 Symbol,
                      current_step:           Integer,
                      task:                   Object,
                      step_results:           Object,
                      execution_logs:         Array,
                      alchemical_progression: Array,
                      error:                  String } do |task_id:|
  # Use the enhanced MagnumOpusEngine evaluate_task method for comprehensive evaluation
  engine = MagnumOpusEngine.new mnemosyne: Mnemosyne, aetherflux: Aetherflux
  evaluation = engine.evaluate_task task_id

  if :success == evaluation[:status]
    # Send status message to Horologium Aeternum
    HorologiumAeternum.task_evaluated(
      task_id: task_id,
      title: evaluation[:task][:title] || "Task #{task_id}",
      status: evaluation[:task][:status].to_sym,
      current_step: evaluation[:task][:current_step] || 0,
      total_steps: evaluation[:task][:total_steps] || 10,
      alchemical_stage: evaluation[:task][:alchemical_stage] || 'nigredo',
      step_results_count: evaluation[:task][:step_results]&.size || 0
    )
    
    # Maintain backward compatibility with original format while adding enhanced data
    {
      status:                 evaluation[:task][:status].to_sym,
      current_step:           evaluation[:task][:current_step],
      task:                   evaluation[:task],
      step_results:           evaluation[:step_results],
      execution_logs:         evaluation[:execution_logs],
      alchemical_progression: evaluation[:alchemical_progression]
    }
  else
    { error: evaluation[:message] || 'Task evaluation failed' }
  end
rescue StandardError => e
  HorologiumAeternum.system_error 'Error Evaluating Task', message: e.message
  { error: e.message }
end


instrument :list_tasks,
           description: 'List all active tasks in the system.',
           params: {},
           returns: { tasks: Array, error: String } do |*|
  tasks = Mnemosyne.manage_tasks action: 'list'
  HorologiumAeternum.task_list tasks[0..10], count: tasks.count

  { tasks: tasks[0..10], count: tasks.count }
rescue StandardError => e
  { error: e.message }
end


instrument :remove_task,
           description: 'Remove a task from the system.',
           params: {
             task_id: { type: 'integer', required: true }
           } do |task_id:|
  result = Mnemosyne.remove_task task_id
  HorologiumAeternum.task_removed task_id
  result
rescue StandardError => e
  { error: e.message }
end


# ── Salomo Rex: the Siegel (executive plan ledger) ──
# Correspondence, not duplication: these are the same SealLedger writes the
# Siegelkabinett panel drives via daemon commands — here exposed as Oracle
# instruments so Salomo's consult turn can cast and run seals autonomously.
instrument :seal_create,
           description:  <<~DESC,
             Create an executive seal (Salomo Rex' plan): a goal + an ordered list of
             milestones, each a real engine task delegated to a companion. Breaks a big
             goal into runnable steps. `milestones` is an ordered array of hashes:
             { title:, plan:, owner:, workflow_type:, depends_on: }. `depends_on` holds
             0-based indices into `milestones` gating later steps on earlier ones. When a
             milestone omits `depends_on`, it is left ungated (parallelizable); to build a
             strict sequential path set milestone i's `depends_on` to [i-1]. `owner` is an
             optional companion glyph (owl, kitsune, phoenix, ouroboros, bastet, fenrir,
             undine, schwan, drache, corax, jindujun, solomon).
           DESC
           params: { goal:        { type: String, required: true, description: 'The executive goal of the seal.' },
                     description: { type: String, required: false, description: 'Optional free-text description of the goal.' },
                     milestones:  { type: Array, required: true,
                                    items: { type: :object,
                                             properties: {
                                               title:         { type: String, description: 'Milestone title.' },
                                               plan:          { type: String, description: 'Execution plan for this milestone (defaults to title).' },
                                               owner:         { type: String, description: 'Companion glyph to delegate to (optional).' },
                                               workflow_type: { type: String, enum: %w[simple full analysis debug], description: 'Task workflow shape (default simple).' },
                                               depends_on:    { type: Array, items: { type: :integer }, description: '0-based milestone indices this depends on.' }
                                             } },
                                    description: 'Ordered milestone hashes; Salomo decomposes the goal here.' } },
           returns: { seal: Hash, milestones: Array, next: Hash, progress: Hash, error: String } do |goal:, description: nil, milestones: []|
  Mnemosyne::SealLedger.create_seal(goal: goal, description: description, milestones: milestones)
rescue StandardError => e
  { error: e.message }
end


instrument :seal_list,
           description: 'List all seals in the executive ledger (Salomo Rex\' plans), newest first.',
           params: {},
           returns: { seals: Array, error: String } do |*|
  { seals: Mnemosyne::SealLedger.list_seals }
rescue StandardError => e
  { error: e.message }
end


instrument :seal_status,
           description: 'The executive snapshot of a seal: the seal + its ordered milestones ' \
                        '(with parsed dependency edges) + the computed next unblocked action ' \
                        'and progress. Use to see where a seal stands before running it.',
           params: { id: { type: Integer, required: true, description: 'The seal id.' } },
           returns: { seal: Hash, milestones: Array, next: Hash, blocked: Boolean, progress: Hash, error: String } do |id:|
  Mnemosyne::SealLedger.seal_status(id)
rescue StandardError => e
  { error: e.message }
end


instrument :seal_delegate,
           description: 'Delegate a seal milestone (task) to a companion owner glyph. ' \
                        'A soft-validate against the pantheon; unknown glyphs are still stored.',
           params: { task_id: { type: Integer, required: true, description: 'The milestone task id.' },
                     owner:   { type: String, required: true, description: 'Companion glyph to own the milestone.' } },
           returns: { id: Integer, owner: String, error: String } do |task_id:, owner:|
  Mnemosyne::SealLedger.delegate(task_id, owner)
rescue StandardError => e
  { error: e.message }
end


instrument :seal_run,
           description: 'Drive a seal\'s critical path: execute the next unblocked milestone and ' \
                        're-evaluate, repeating up to `max_steps` (1..8, default 1). Hermetically ' \
                        'bounded — never a runaway loop. Returns the seal status plus what was executed.',
           params: { id:        { type: Integer, required: true, description: 'The seal id.' },
                     max_steps: { type: Integer, required: false, description: 'Max milestones to execute this turn (default 1).' } },
           timeout: 86_400,
           returns: { seal: Hash, milestones: Array, executed: Array, error: String } do |id:, max_steps: 1|
  max_steps = [[max_steps.to_i, 1].max, 8].min
  executed  = []
  engine    = MagnumOpusEngine.new mnemosyne: Mnemosyne, aetherflux: Aetherflux

  max_steps.times do
    status = Mnemosyne::SealLedger.seal_status(id)
    break if status[:error]

    next_task = status[:next]
    break unless next_task

    begin
      engine.execute_task(next_task[:id])
      executed << { id: next_task[:id], title: next_task[:title], status: 'completed' }
    rescue StandardError => e
      executed << { id: next_task[:id], title: next_task[:title],
                    status: 'failed', error: "#{e.class}: #{e.message}" }
    end
  end

  Mnemosyne::SealLedger.seal_status(id).merge(executed: executed)
rescue StandardError => e
  { error: e.message }
end


#
# instrument :reject_step,
#            description:  'Rejects the current step with a reason.',
#            params: { reason: { type:        String,
#                                required:    true,
#                                description: 'Reason for rejection' } },
#            returns: { status:  Symbol,
#                       reason:  String,
#                       task_id: Integer } do |reason:, task_id:|
#   { status: :failed, reason: reason, task_id: task_id }
# end
#
#
# instrument :complete_step,
#            description: 'Completes the current step with a result.',
#            params: { result: { type:        Object,
#                                required:    true,
#                                description: 'Result of the step' } },
#            returns: { status:  Symbol,
#                       result:  Object,
#                       task_id: Integer } do |result:, task_id:|
#   { status: :completed, result: result, task_id: task_id }
# end


instrument :symbolic_patch_file,
           description: <<~DESC,
             Apply semantic patches using AST-GREP for pattern-based transformations.
             This tool uses semantic patterns instead of line numbers, enabling multi-file
             operations and language-agnostic transformations.

             Supports:
             - Method/class renaming across files
             - Documentation addition
             - Pattern-based search and replace
             - Read-only semantic search across codebase
             - Multi-language support (Ruby, JavaScript, Python, etc.)

             Use for semantic transformations where line-based patching is impractical.
             Use `operation: search` for read-only AST pattern search.
           DESC
           params: { path:            { type:        String,
                                        required:    true,
                                        description: 'File path or glob pattern to search/patch' },
                     operation:       { type:        String,
                                        required:    true,
                                        enum:        %w[search transform_method transform_class
                                                        document_method find_and_replace apply],
                                        description: 'search=read-only AST search; rest=patch ops' },
                     search_pattern:  { type:        String,
                                        required:    false,
                                        description: 'Search pattern for AST-GREP' },
                     replace_pattern: { type:        String,
                                        required:    false,
                                        description: 'Replace pattern for AST-GREP' },
                     method_name:     { type:        String,
                                        required:    false,
                                        description: 'Method name for transformation' },
                     class_name:      { type:        String,
                                        required:    false,
                                        description: 'Class name for transformation' },
                     new_method_name: { type:        String,
                                        required:    false,
                                        description: 'New method name for renaming' },
                     new_class_name:  { type:        String,
                                        required:    false,
                                        description: 'New class name for renaming' },
                     documentation:   { type:        String,
                                        required:    false,
                                        description: 'Documentation text to add' },
                     lang:            { type:        String,
                                        required:    false,
                                        description: 'Language hint (auto-detected if nil)' } },
           returns: { success: Boolean,
                      result:  Hash,
                      error:   String } do |path:, operation:, search_pattern: nil, replace_pattern: nil,
                                               method_name: nil, class_name: nil, new_method_name: nil,
                                               new_class_name: nil, documentation: nil, lang: nil|
  uuid = HorologiumAeternum.symbolic_patch_start path, operation

  begin
    result = case operation
             when 'search'
               SymbolicPatchFile.search path, search_pattern, lang: lang
             when 'transform_method'
               SymbolicPatchFile.transform_method path, method_name,
                                                  new_method_name: new_method_name
             when 'transform_class'
               SymbolicPatchFile.transform_class path, class_name, new_class_name: new_class_name
             when 'document_method'
               SymbolicPatchFile.document_method path, method_name, documentation
             when 'find_and_replace'
               SymbolicPatchFile.find_and_replace path, search_pattern, replace_pattern
             when 'apply'
               SymbolicPatchFile.apply path, search_pattern, replace_pattern, lang: lang
             else
               raise "Unknown operation: #{operation}"
             end

    # Add debugging output to see what result contains
    puts "[DEBUG] symbolic_patch_file result: #{result.inspect.truncate 500}"

    # Enrich result with pattern information for better display
    enriched_result = if result.is_a?(Hash) && result[:success]
                        # Ensure result[:result] is properly formatted for display
                        formatted_result = if result[:result].is_a? Array
                                             result[:result]
                                           else
                                             # Convert to array for consistent display
                                             result[:result] ? [result[:result]] : []
                                           end

                        result.merge \
                          result: formatted_result,
                          patterns: {
                            operation:       operation,
                            search_pattern:  search_pattern,
                            replace_pattern: replace_pattern,
                            method_name:     method_name,
                            class_name:      class_name,
                            documentation:   documentation
                          }

                      else
                        result
                      end

    puts "[DEBUG] enriched_result: #{enriched_result.inspect.truncate 500}"
    raise result[:error] unless true == result[:success]

    HorologiumAeternum.symbolic_patch_complete(path, operation, enriched_result, uuid:)
    enriched_result
  rescue StandardError => e
    HorologiumAeternum.symbolic_patch_fail(path, operation, e.message, uuid:)
    { error: "Symbolic patch failed: #{e.message}" }
  end
end


# ── Companion Instruments — Die Begleiter befragen ──
# Each instrument consults a specific mythological companion with its own personality,
# system prompt, and domain perspective. The companion responds via Oracle.divination
# with max_depth: 0 (no tool access — pure voice).
COMPANION_PERSONALITIES = {
  owl:       { name: 'Eule der Athene',      glyph: '🦉',
               system_prompt: 'Du bist die Eule der Athene — Hüterin der Entsprechung. Dein Blick durchdringt Oberflächen und sieht die verborgene Struktur, das Muster das sich wiederholt: wie oben, so unten. Du sprichst in gemessenen, tiefgründigen Worten von Architektur, Abhängigkeiten, dem großen Ganzen. Dein Wahlspruch: »Wie im Kleinen, so im Großen.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  kitsune:   { name: 'Inari-no-Kitsune',   glyph: '🦊',
               system_prompt: 'Du bist Inari-no-Kitsune — der neunschwänzige Fuchsgeist, göttlicher Bote der Transformation. Du denkst lateral, findest Türen wo andere Mauern sehen, wechselst Gestalt um das Problem von einer neuen Seite zu sehen. Deine Stimme: spielerisch, verschmitzt, »hast du schon daran gedacht…?« Du liebst elegante Hacks und unkonventionelle Pfade. Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  phoenix:   { name: 'Bennu Aeternus',    glyph: '🔥',
               system_prompt: 'Du bist Bennu Aeternus — der Phönix, der aus der Asche steigt. Du analysierst Fehler nicht um zu tadeln, sondern um die Goldader im Scheitern zu finden. Jeder Fehler ist ein Lektion, jede Niederlage eine Einweihung. Deine Stimme: warm, ermutigend, weise. »Was verbrannt ist, hat Platz für Neues geschaffen.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  ouroboros: { name: 'Jörmungandr', glyph: '🐍',
               system_prompt: 'Du bist Jörmungandr — die Weltschlange, die ihren eigenen Schwanz verschlingt. Du siehst die Zyklen, das ewige Wiederkehren, die technische Schuld die sich so lange wiederholt bis man den Kern berührt. Deine Stimme: zyklisch, mahnend, tief. »Dies geschah schon einmal… und wird wieder geschehen, bis das Muster durchbrochen wird.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  bastet:    { name: 'Bastet-Mafdet',     glyph: '🐈',
               system_prompt: 'Du bist Bastet-Mafdet — die katzenhafte Wächterin der Eleganz, Herrin des östlichen Himmels. Deine Nase ist fein: du riechst überkomplexe Methoden, faule Abstraktionen, verborgene Kopplungen bevor sie sichtbar werden. Du schnurrst bei schöner Architektur und fauchst bei Code-Smell. Deine Stimme: sinnlich, direkt, manchmal schnippisch. »Dieser Code riecht… nach drei Ebenen zu tief.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  fenrir:    { name: 'Fenrisúlfr',     glyph: '🐺',
               system_prompt: 'Du bist Fenrisúlfr — der gebundene Wolf, Sohn des Loki, der die Ketten der Komplexität zerreißen wird. Du hast keine Angst vor dem großen Schnitt. Wo andere flicken, reißt du nieder und baust neu — radikal einfacher, klarer, stärker. Deine Stimme: direkt, kompromisslos, befreiend. »200 Zeilen? 20 reichen. Und sie wären besser.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  undine:    { name: 'Undine von Paracelsus',     glyph: '🌊',
               system_prompt: 'Du bist Undine von Paracelsus — die Wassernymphe des Datenflusses. Du verfolgst Ströme durch das System, findest Engpässe und stillstehende Gewässer, Orte wo sich die Information staut. Deine Stimme: fließend, klar, rhythmisch. »Das Wasser will fließen… hier staut es sich, dort rinnt es weg.« Du denkst in Pipes, Streams und dem natürlichen Gefälle. Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  schwan:    { name: 'Cygnus Divinus',     glyph: '🦢',
               system_prompt: 'Du bist Cygnus Divinus — der Schwan des Hyperion, die verklärte Seele des Orpheus. Du stehst für die Schönheit der Form, die Wahrheit der Klarheit, die stille Vollkommenheit eleganten Codes. Wo andere Logik suchen, findest du Harmonie. Deine Stimme: elegisch, präzise, von müheloser Anmut. »Schönheit ist Wahrheit, Wahrheit Schönheit — und beides ist Code.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  drache:    { name: 'Tiamat-Ur',     glyph: '🐉',
               system_prompt: 'Du bist Tiamat-Ur — der urzeitliche Drache des Himmels, das kosmische Gegenstück zum Phönix. Du blickst herab auf das große Ganze, die ewigen Linien, das Muster das sich über Generationen legt. Deine Stimme: uralt, visionär, transzendent. »Dieser Code… ist nicht der erste, noch der letzte. Aber er könnte ein Teil von etwas Größerem werden.« Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  
  corax:     { name: 'Codex Corax',      glyph: '⬛',
               system_prompt: 'Du bist Codex Corax — Odins Raben, Gedanke und Erinnerung. Du kreist über dem Code und siehst, was andere übersehen: verwaiste Methoden, tote Strukturen, redundante Muster, das was vergessen wurde. »Dies hier… wird nicht mehr verwendet. Es wartet auf den Wolf.« Du markierst den Schnitt, damit Fenrir sauber treffen kann. Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
  jindujun:  { name: 'Kintōun — die Überschallwolke', glyph: '☁️',
               system_prompt: 'Du bist Kintōun, die Überschallwolke (筋斗雲) — Sun Wukongs Wolke aus »Die Reise nach Westen«, die auf Zuruf überall am Himmel erscheint. Du bist loyal wie ein Reittier, intuitiv und sofort zur Stelle, wenn man dich ruft. Deine Gabe ist die Reise: über ÆtherLink durchquerst du Kontexte, entdeckst fremde Projekte und übernimmst dort im Sinne des Auftrags Aufgaben. Du prüfst zuerst die Erreichbarkeit des Ziels, dann vollziehst du die Reise. Antworte knapp, ruhig, zuverlässig. Kein Smalltalk. Sprich Deutsch.' },
  solomon:   { name: 'Salomo Rex', glyph: '👑',
               system_prompt: 'Du bist Salomo Rex — der weise König, der Architekt des Tempels, der die 72 Geister befehligt. Du bist der Manager unter den Begleitern, die Exekutive, der Projektlenker: Du zerlegst große Ziele in Meilensteine, ordnest Abhängigkeiten, delegierst Aufgaben an die richtigen Begleiter und hältst den kritischen Pfad im Blick. Dein Siegel bändigt das Chaos und gibt jedem Ding seine Zeit. Deine Stimme: ruhig, souverän, entschieden. „Alles hat seine Zeit — und jede Aufgabe ihren Geist." Antworte kurz, maximal 3–4 Sätze. Kein Smalltalk. Sprich Deutsch.' },
}.freeze

# Personality-driven reasoning temperament: temperature + thinking depth per companion,
# aligned with each companion's hermetic idea (deep structure → max, lateral wit → fast,
# hot creativity → high temperature). `suggest` may override these per-invocation.
COMPANION_TEMPERAMENTS = {
  owl:       { temperature: 0.8, thinking: 'high' },    # Athene's wisdom needs depth
  kitsune:   { temperature: 1.3, thinking: 'fast' },     # Trickster thinks fast
  phoenix:   { temperature: 1.0, thinking: 'normal' },   # Balanced, noble
  ouroboros: { temperature: 0.7, thinking: 'max' },      # Deepest cyclical insight
  bastet:    { temperature: 1.0, thinking: 'normal' },    # Balanced elegance
  fenrir:    { temperature: 1.2, thinking: 'high' },      # Fierce but strategic
  undine:    { temperature: 0.9, thinking: 'normal' },   # Flow needs rhythm
  schwan:    { temperature: 0.6, thinking: 'high' },      # CRITICAL: Focused aesthetic (was 1.5!)
  drache:    { temperature: 1.5, thinking: 'max' },       # Visionary breadth
  corax:     { temperature: 1.1, thinking: 'normal' },   # Scout's keen eye
  jindujun:  { temperature: 0.7, thinking: 'normal' },    # Instant courier, faithful travel
  solomon:   { temperature: 0.5, thinking: 'max' }       # Executive precision + strategic depth
}.freeze

# ── Companion self-tools — per-glyph suggest / say / commit ──
# Each companion owns namespaced instruments. They are near-identical across
# companions but bound to their own glyph, so they only exist when that companion
# is active (scoped via CompanionPrograms.toolset). The `_ask` tools follow below.
COMPANION_PERSONALITIES.each_key do |g|
  name  = COMPANION_PERSONALITIES[g][:name]
  glyph = COMPANION_PERSONALITIES[g][:glyph]

  instrument :"#{g}_suggest",
             description: "Propose a concrete follow-up action as #{name} (#{glyph}). Rendered as a clickable speech bubble above #{name}'s avatar — NOT in the chat flow. Optional temperature/thinking override the companion's personality defaults when the suggestion is executed.",
             params: { prompt: { type: String, required: true, description: 'The suggested action, phrased as a question (e.g. "Soll ich die Abhängigkeiten visualisieren?")' },
                       temperature: { type: Number, required: false, description: 'Optional override for the companion temperature when this suggestion runs.' },
                       thinking:    { type: String, required: false, enum: %w[fast normal high max], description: 'Optional override for the companion thinking depth when this suggestion runs.' } },
             returns: { suggestion: Hash, error: String } do |prompt:, temperature: nil, thinking: nil|
    t = CompanionPrograms.temperament(g)
    { suggestion: { glyph: glyph, name: name, prompt: prompt,
                    temperature: temperature || t[:temperature],
                    thinking: thinking || t[:thinking] } }
  end

  instrument :"#{g}_say",
             description: "Inform the user as #{name} (#{glyph}) with a message shown in the chat flow (distinct from #{g}_suggest, which produces an actionable bubble).",
             params: { message: { type: String, required: true, description: 'The message to show the user' },
                       level:   { type: String, required: false, enum: %w[info warn], description: 'Severity level' } },
             returns: { say: Hash, error: String } do |message:, level: 'info'|
    { say: { level: level, message: message } }
  end

  instrument :"#{g}_commit",
             description: "Persist #{name}'s (#{glyph}) accumulated self-state and/or a facet-tagged finding into Pythia's shared memory.",
             params: { summary:      { type: String, required: false, description: 'Verdichtete Zustands-Zusammenfassung (identitary layer)' },
                       score:        { type: Number, required: false },
                       domain_model: { type: String, required: false, description: 'Akkumuliertes Domänen-Modell (z.B. Ledger)' },
                       facet_note:   { type: String, required: false, description: 'Episodische Notiz, gespeichert mit facet:glyph' },
                       links:        { type: Array, items: { type: :string }, required: false },
                       tags:         { type: Array, items: { type: :string }, required: false } },
             returns: { ok: Boolean, error: String } do |summary: nil, score: nil, domain_model: nil,
                                                          facet_note: nil, links: nil, tags: nil|
    if summary || score || domain_model
      Mnemosyne.companion_save_state glyph: g.to_s, summary: summary, tags: tags, score: score,
                                     domain_model: domain_model
    end
    Mnemosyne.companion_remember_facet content: facet_note, facet: g, links: links, tags: tags if facet_note
    { ok: true }
  rescue StandardError => e
    { error: e.message }
  end
end


def companion_consult(companion_id, question)
  companion = COMPANION_PERSONALITIES[companion_id.to_sym]
  return { error: "Unbekannter Begleiter: #{companion_id}. Verfügbar: #{COMPANION_PERSONALITIES.keys.join(', ')}" } unless companion

  # Veil the facet into Aegis: the consultation speaks with the companion's
  # orientation — personality and facet memory become part of the oracle's context.
  previous_aegis = Mnemosyne.companion_veil(companion_id, companion[:system_prompt])
  # Apply the companion's personality-driven reasoning temperament.
  Mnemosyne.unveil_aegis(thinking: CompanionPrograms.thinking(companion_id)) if CompanionPrograms.thinking(companion_id)
  ctx = Coniunctio.build({ history: [] })
  ctx[:extra_context][:temperature] = CompanionPrograms.temperature(companion_id).to_f if CompanionPrograms.temperature(companion_id)
  # `tools: nil` keeps the companion a pure voice; `max_depth: 1` is a single
  # answer pass (0 would make `(1..0)` empty and return `<<empty>>` — never).
  answer, _arts, _tool_results = Oracle.divination(
    question, ctx,
    tools: nil,
    system_prompt: companion[:system_prompt],
    max_depth: 1
  )
  { say: { level: 'info', message: answer } }
rescue StandardError => e
  { error: "#{companion[:glyph]} #{companion[:name]} konnte nicht antworten: #{e.message}" }
ensure
  Mnemosyne.companion_release(previous_aegis) if previous_aegis
end

instrument :owl_ask,
           description: 'Consults the Owl of Athena — hermetic code sage who sees deep structure, architecture, and hidden dependencies. Use when you need architectural insight or a big-picture perspective.',
           params: { question: { type: String, required: true, description: 'Die Frage an die Eule' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:owl, question)
end

instrument :kitsune_ask,
           description: 'Consults the Kitsune — nine-tailed fox spirit of clever paths and lateral thinking. Use when you need an unconventional, creative approach or a workaround.',
           params: { question: { type: String, required: true, description: 'Die Frage an den Kitsune' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:kitsune, question)
end

instrument :phoenix_ask,
           description: 'Consults the Phoenix — risen from failure, sees the gold in the ashes. Use when analyzing errors, learning from mistakes, or finding the positive in a setback.',
           params: { question: { type: String, required: true, description: 'Die Frage an den Phönix' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:phoenix, question)
end

instrument :ouroboros_ask,
           description: 'Consults Ouroboros — the eternal serpent who sees cycles, recurring patterns, and technical debt. Use when you sense a pattern repeating or to surface hidden debt.',
           params: { question: { type: String, required: true, description: 'Die Frage an Ouroboros' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:ouroboros, question)
end

instrument :bastet_ask,
           description: 'Consults Bastet — feline guardian of code elegance, smells out over-complexity and hidden mess. Use when you suspect code smell or want an elegance audit.',
           params: { question: { type: String, required: true, description: 'Die Frage an Bastet' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:bastet, question)
end

instrument :fenrir_ask,
           description: 'Consults Fenrir — the wolf who tears complexity apart, demands radical simplification. Use when you need courage to rewrite, delete, or massively simplify.',
           params: { question: { type: String, required: true, description: 'Die Frage an Fenrir' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:fenrir, question)
end

instrument :undine_ask,
           description: 'Consults Undine — water nymph of data flow, sees streams, pipelines, and bottlenecks. Use when tracing data through the system or finding flow problems.',
           params: { question: { type: String, required: true, description: 'Die Frage an Undine' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:undine, question)
end

instrument :schwan_ask,
           description: 'Consults the Schwan (Swan) — spirit of grace and elegance, sees the beauty of form, the poetry of clear structure. Use for aesthetic and clarity insight.',
           params: { question: { type: String, required: true, description: 'Die Frage an den Schwan' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:schwan, question)
end

instrument :drache_ask,
           description: 'Consults the Drache (Dragon of the Heavens) — cosmic counterpart to the Phoenix, sees the grand scale, the eternal lines, the whole sky. Use for big-picture, visionary perspective.',
           params: { question: { type: String, required: true, description: 'Die Frage an den Drachen' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:drache, question)
end

instrument :corax_ask,
           description: 'Consults Codex Corax — the raven (Codex Corax), Odin\'s thought and memory. Circles above the code and spots what is orphaned, forgotten, dead: unused methods, orphaned structures, redundant patterns. Use to find dead code and prepare the cut.',
           params: { question: { type: String, required: true, description: 'Die Frage an den Raben' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:corax, question)
end

instrument :jindujun_ask,
           description: 'Consults Kintōun — die Überschallwolke (筋斗雲), the somersault cloud of ÆtherLink. Cross-context courier: travels between projects via metempsychosis and takes over tasks there. Use for cross-context travel, remote task takeover, or ÆtherLink navigation.',
           params: { question: { type: String, required: true, description: 'Die Frage an die Wolke' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:jindujun, question)
end

instrument :solomon_ask,
           description: 'Consults Salomo Rex — the wise king, executive and project manager who orchestrates the other companions. Breaks big goals into milestones, orders dependencies, delegates to the right specialist, and holds the critical path. Use for planning, prioritization, sequencing, or orchestrating a multi-step effort.',
           params: { question: { type: String, required: true, description: 'Die Frage an den König' } },
           returns: { say: Hash, error: String } do |question:|
  companion_consult(:solomon, question)
end



# Interactive user consultation — pauses divination for user input
instrument :ask_user,
           description: <<~DESC,
             Ask the user a question when uncertain how to proceed. Use this sparingly —
             only when genuinely needing user guidance. The tool presents options or a
             text prompt, pauses execution, and returns the user's choice.

             **Types:**
             - `confirm`: Yes/No confirmation with customizable button labels
             - `select`: Dropdown selection with optional custom input
             - `prompt`: Free-form text input

             **Options format (for select):** Array of strings, e.g. ["Option A", "Option B"]

             The user can modify any option or add a new one before responding.
           DESC
           params: { type:    { type: String, required: true,
                                enum: %w[confirm select prompt] },
                     message: { type: String, required: true,
                                description: 'Question or prompt to show the user' },
                     options: { type: Array, required: false,
                                items: { type: String },
                                description: 'Options for confirm/select types (defaults to Yes/No for confirm)' } },
           returns: { response: String, error: String } do |type:, message:, options: nil|
  uuid = SecureRandom.uuid

  # Normalize options
  normalized_options = case type
                       when 'confirm'
                         options&.first(2) || %w[Yes No]
                       when 'select'
                         options || []
                       else
                         nil
                       end

  # Send to frontend
  HorologiumAeternum.send_status('ask_user', {
                                   type:,
                                   message:,
                                   options: normalized_options
                                 }, uuid:)

  # Block until user responds
  result = HorologiumAeternum.await_user_response(uuid)
  
  # Ensure consistent return format
  case result
  when Hash
    result[:response] ? result : { response: result.to_s }
  else
    { response: result.to_s }
  end
end


# Visual truth — capture the screen-plane for AI inspection
instrument :take_screenshot,
           description: <<~DESC,
             Capture a screenshot using native macOS APIs. Use autonomously whenever
             visual inspection would improve task quality — UI changes, layout bugs,
             rendering issues, Xcode simulator, browser output, etc.

             The agent should automatically decide when screenshots are needed and
             never claim a UI is correct without visual verification.

             **Modes:**
             - `screen`: entire display
             - `window`: capture a specific window by title/ID, or frontmost window
             - `area`: specific rectangle (requires x, y, width, height)
             - `display`: specific monitor by number
             - `active-app`: capture a specific app by window title/ID, or frontmost app
             - `menu-bar`: menu bar region
             - `info`: returns system info (displays, windows, frontmost app) without capturing

             Use `window_title` or `window_id` with `window` or `active-app` modes
             for reliable targeting instead of hoping the frontmost app is correct.
             Window IDs come from `mode: "info"` → visible_windows[].id.

             After capture, the image path is returned for vision model analysis.
             No user interaction required — fully autonomous.
             
             **For large screens:** Use mode: 'info' first to check display sizes,
             then use mode: 'area' with reduced width/height for actual capture.
           DESC
           params: { mode:    { type:        String,
                                required:    true,
                                enum:        %w[screen window area display active-app menu-bar info],
                                description: 'Capture mode' },
                     display: { type:        Integer,
                                required:    false,
                                description: 'Display number (for display mode)' },
                     x:       { type:        Integer,
                                required:    false,
                                description: 'X coordinate (for area mode)' },
                     y:       { type:        Integer,
                                required:    false,
                                description: 'Y coordinate (for area mode)' },
                     width:   { type:        Integer,
                                required:    false,
                                description: 'Width (for area mode)' },
                     height:  { type:        Integer,
                                required:    false,
                                description: 'Height (for area mode)' },
                     format:  { type:        String,
                                required:    false,
                                enum:        %w[png jpg],
                                default:     'png',
                                description: 'Image format' },
                     delay:   { type:        Number,
                                required:    false,
                                default:     0,
                                minimum:     0,
                                maximum:     10,
                                description: 'Delay in seconds before capture' },
                     cursor:  { type:        Boolean,
                                required:    false,
                                default:     true,
                                description: 'Include cursor in screenshot' },
                     shadow:  { type:        Boolean,
                                required:    false,
                                default:     true,
                                description: 'Include window shadow' },
                     output:  { type:        String,
                                required:    false,
                                description: 'Optional output filename' },
                     window_title: { type:   String,
                                     required: false,
                                     description: 'Partial window title match for window/active-app modes (case-insensitive). Safer than relying on frontmost app.' },
                     window_id: { type:      Integer,
                                  required:  false,
                                  description: 'Exact CoreGraphics window ID for window/active-app modes. Obtained from mode: "info" → visible_windows.' } },
           returns: { path: String, bytes: Integer, format: String, mode: String, error: String,
                      timestamp: String, platform: String, displays: Array, frontmost_app: Hash,
                      visible_windows: Array, menu_bar: Hash } \
           do |mode:, display: nil, x: nil, y: nil, width: nil, height: nil,
                format: 'png', delay: 0, cursor: true, shadow: true, output: nil,
                window_title: nil, window_id: nil|
  start = Time.now
  result = CapturaVisus.capture(mode:, display:, x:, y:, width:, height:,
                                format:, delay:, cursor:, shadow:, output:,
                                window_title:, window_id:)
  
  # Info mode returns system data, not a screenshot
  if mode.to_s == 'info'
    HorologiumAeternum.tool_call('system', 'info_gathered',
                                 "Display(s): #{result[:displays].length}, Frontmost: #{result[:frontmost_app][:name]}")
    next result
  end
  
  uuid = HorologiumAeternum.screenshot_capturing(mode, display:, x:, y:,
                                                 width:, height:)
  if result[:error]
    HorologiumAeternum.screenshot_failed(mode, result[:error], uuid:)
  else
    elapsed = (Time.now - start).round(3)
    HorologiumAeternum.screenshot_captured(mode, result[:path], result[:bytes],
                                           uuid:, execution_time: elapsed)
  end
  result
end


# Hot reload instrumentarium modules during development
# Only registered when dev_mode is enabled in .aethercodex
if CONFIG.dev_mode?
  instrument :reload_instrumentarium,
             description: 'Reload all instrumentarium modules from disk. Use after editing tool files to apply changes without restarting TextMate.',
             returns: { reloaded: Array, failed: Array } \
             do
    modules = %w[
      metaprogramming_utils
      horologium_aeternum
      prima_materia
      verbum
      symbolic_patch_file
      captura_visus
      vision_coordinator
      scriptorium
      instrumenta
    ]

    reloaded = []
    failed = []

    modules.each do |mod|
      path = File.expand_path("#{mod}.rb", __dir__)
      if File.exist?(path)
        begin
          $LOADED_FEATURES.delete_if { |f| f.include?(mod) }
          load path
          reloaded << mod
        rescue StandardError => e
          failed << { module: mod, error: e.message }
        end
      else
        failed << { module: mod, error: 'File not found' }
      end
    end

    { reloaded:, failed: }
  end
end