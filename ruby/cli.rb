#!/usr/bin/env ruby
# frozen_string_literal: true

# = ÆtherCodex CLI — Console-first Hermetic Programming Oracle
#
# Subcommands:
#   ask "prompt"    Direct AI query (stdin pipe supported)
#   server            Start web server (TextMate UI)
#   config            Show configuration info
#   task <action>     Task management (list, show, create, execute)
#   (no args)         Interactive REPL with tool execution

require 'json'
require 'optparse'
require_relative 'config'
require_relative 'oracle/oracle'
require_relative 'oracle/terminal_stream'
require_relative 'oracle/coniunctio'
require_relative 'oracle/aetherflux'
require_relative 'instrumentarium/instrumenta'
require_relative 'instrumentarium/prima_materia'
require_relative 'mnemosyne/mnemosyne'
require_relative 'magnum_opus/magnum_opus_engine'

class ÆtherCodexCLI
  def initialize
    @options = {}
    @tools = Instrumenta
    @history = []
  end

  def run
    command = ARGV.shift

    case command
    when 'ask'     then ask_mode
    when 'server'  then server_mode
    when 'config'  then config_mode
    when 'context' then context_mode
    when 'task'    then task_mode
    when 'logs'    then logs_mode
    when 'repl'    then repl_mode
    when 'veil'    then veil_mode
    when 'help', '-h', '--help' then print_help
    when nil       then repl_mode
    else
      ARGV.unshift(command) if command
      repl_mode
    end
  end

  private

  def ask_mode
    prompt = ARGV.join(' ').strip
    prompt = STDIN.read.strip if prompt.empty? && !STDIN.tty?

    if prompt.empty?
      puts "Usage: ÆtherCodex ask \"your question\""
      puts "   or: echo \"question\" | ÆtherCodex ask"
      exit 1
    end

    # Parse --file options
    files = []
    args = prompt.split
    while (idx = args.index('--file') || args.index('-f'))
      args.delete_at(idx)
      files << args.delete_at(idx)
    end
    prompt = args.join(' ')

    interactive = $stdin.tty? && $stdout.tty?
    terminal_stream = interactive ? TerminalStream.new : nil
    tools = interactive ? @tools : @tools.reject(:ask_user)
    context = Coniunctio.build(files: files)
    previous_stream = Thread.current[:aether_terminal_stream]
    Thread.current[:aether_terminal_stream] = terminal_stream
    answer, arts, tool_results = Oracle.divination(prompt, context, tools:, stream: terminal_stream) do |name, args, tool_ctx|
      tools.handle(tool: name, args:, context: tool_ctx)
    end
    puts answer
  ensure
    Thread.current[:aether_terminal_stream] = previous_stream
  end

  def server_mode
    puts "Starting server..."
    require_relative 'limen'
    Limen.start
  end

  def config_mode
    puts "=== ÆtherCodex Configuration ==="
    puts "Model: #{CONFIG.model}"
    puts "API type: #{CONFIG.api_type}"
    puts "Flash model: #{CONFIG.fast_model}"
    puts "API Key: #{CONFIG.api_key.to_s[0..8]}..." if CONFIG.api_key
    puts "Memory DB: #{CONFIG.memory_db_path}"
    puts "Project Root: #{CONFIG.project_root}"
    puts "Config Sources: #{CONFIG.debug_info[:config_sources]}"
  end

  def context_mode
    action = ARGV.shift || 'show'

    case action
    when 'show', 'info', 'status' then context_show
    when 'init', 'create'          then context_create
    when 'list', 'ls'              then context_list
    else
      puts "Unknown context action: #{action}"
      puts 'Available: show | init [name] [--path DIR] | list'
      exit 1
    end
  end

  def context_show
    root = CONFIG.project_root
    cfg = CONFIG.config_file_in(root) || File.join(root, '.aethercodex')
    mem = CONFIG.memory_db_path

    puts '=== Æther Context ==='
    puts "Name:      #{CONFIG.project_name}"
    puts "Root:      #{root}  #{File.exist?(root) ? '' : '(MISSING)'}"
    puts "Config:    #{File.exist?(cfg) ? cfg : "#{cfg} (none — init with: aether context init)"}"
    puts "Data dir:  #{CONFIG.tm_ai_dir}"
    puts "Memory DB: #{mem}  #{File.exist?(mem) ? '' : '(empty)'}"
    puts "Source:    #{config_source_label}"
  end

  # A context IS the presence of a `.aethercodex` config file. `init` only
  # materializes that file; from then on every `aether` invocation in this
  # directory (or any subdirectory) derives the context automatically.
  def context_create
    name, target = parse_context_create_args

    FileUtils.mkdir_p(target)
    cfg_path = File.join(target, '.aethercodex')

    existing = {}
    if File.exist?(cfg_path)
      begin
        existing = YAML.load_file(cfg_path) || {}
      rescue StandardError
        existing = {}
      end
    end
    existing = {} unless existing.is_a?(Hash)

    resolved_name = name.to_s.strip
    resolved_name = File.basename(File.expand_path(target)) if resolved_name.empty?
    existing['name'] = resolved_name

    File.write(cfg_path, existing.to_yaml)
    CONFIG.reload! if CONFIG.respond_to?(:reload!)

    puts 'Context materialized:'
    puts "  name:   #{resolved_name}"
    puts "  root:   #{File.expand_path(target)}"
    puts "  config: #{cfg_path}"
    puts
    puts 'This directory (and any subdirectory) now resolves as a context.'
    puts '  aether context   # show it'
  end

  def context_list
    found = discover_contexts

    if found.empty?
      puts 'No .aethercodex contexts found.'
      puts 'Init one with: aether context init [name]'
      return
    end

    found.each do |cfg|
      root = File.dirname(cfg)
      name = read_context_name(cfg) || File.basename(root)
      marker = File.expand_path(root) == File.expand_path(CONFIG.project_root) ? ' *' : ''
      puts "  #{name}  →  #{root}#{marker}"
    end
    puts '  (* = current)'
  end

  # Walk up from the working directory collecting the context chain, then add
  # the home context and any config in immediate home subdirectories.
  def discover_contexts
    found = {}

    current = Pathname.new(File.expand_path(Dir.pwd))
    while current != current.parent
      cfg = CONFIG.config_file_in(current.to_s)
      found[cfg] = true if cfg
      current = current.parent
    end

    home = File.expand_path(Dir.home)
    home_cfg = CONFIG.config_file_in(home)
    found[home_cfg] = true if home_cfg
    Dir[File.join(home, '*')].each do |entry|
      next unless File.directory?(entry)
      next if File.basename(entry).start_with?('.')
      cfg = CONFIG.config_file_in(entry)
      found[cfg] = true if cfg
    end

    found.keys
  end

  def read_context_name(cfg)
    CONFIG.load_config_file(cfg)[:name]
  rescue StandardError
    nil
  end

  def config_source_label
    if CONFIG.loaded_from_project?
      'project (.aethercodex)'
    elsif CONFIG.loaded_from_home?
      'home (~/.aethercodex)'
    elsif CONFIG.loaded_from_bundle?
      'bundle'
    else
      'defaults'
    end
  end

  def parse_context_create_args
    name = nil
    target = Dir.pwd
    args = ARGV.dup

    %w[--path -p].each do |flag|
      i = args.index(flag)
      next unless i
      val = args[i + 1]
      target = val if val && !val.start_with?('-')
      args.delete_at(i + 1) if val
      args.delete_at(i)
    end

    name = args.first unless args.empty?
    [name, File.expand_path(target)]
  end

  def veil_mode
    require_relative 'aether_veil'
    exit AetherVeil.run(ARGV)
  end

  def task_mode
    action = ARGV.shift || 'list'

    case action
    when 'list'
      tasks = Mnemosyne.manage_tasks(action: :list)
      if tasks.empty?
        puts "No tasks found."
      else
        tasks.each do |t|
          status = t[:status] || 'unknown'
          puts "[#{status}] ##{t[:id]}: #{t[:title]}"
        end
      end
    when 'show'
      id = ARGV.shift
      task = Mnemosyne.get_task(id.to_i)
      if task
        puts "Task ##{task[:id]}: #{task[:title]}"
        puts "Status: #{task[:status]}"
        puts "Plan: #{task[:plan]}"
        if task[:step_results]
          puts "Steps:"
          JSON.parse(task[:step_results]).each { |k, v| puts "  #{k}: #{v.to_s[0..100]}" }
        end
      else
        puts "Task ##{id} not found."
      end
    when 'create'
      title = ARGV.shift || 'Untitled Task'
      plan = ARGV.join(' ')
      result = Mnemosyne.create_task(title: title, plan: plan)
      puts "Created task ##{result[:id]}"
    when 'execute'
      id = ARGV.shift
      if id
        Mnemosyne.manage_tasks(action: :activate, id: id.to_i)
        puts "Activated task ##{id}. Use MagnumOpusEngine.execute_task(#{id}) for full execution."
      else
        puts "Usage: ÆtherCodex task execute <id>"
      end
    else
      puts "Unknown task action: #{action}"
      puts "Available: list, show <id>, create <title> [plan], execute <id>"
    end
  end

  def logs_mode
    action = ARGV.shift
    require_relative 'oracle/log_viewer'

    # The tag configurator is a first-class citizen of the log command.
    if action == 'tags' || action == 'config'
      AetherLog::Configurator.new(AetherLog::Registry.new).run(ARGV)
      return
    end

    follow = !%w[dump cat --no-follow].include?(action)
    AetherLog::Viewer.new(
      registry: AetherLog::Registry.new,
      path: find_log_path(follow),
      follow: follow
    ).run
  end

  # Search for the log file in multiple locations, mirroring the old tail.
  # Order: CONFIG log path, project root, home dir. In follow mode the viewer
  # waits for the primary candidate to appear, so the daemon can be started
  # after the viewer.
  def find_log_path(follow)
    candidates = [
      CONFIG.log_file_path,
      File.join(CONFIG.project_root, '.aether', 'limen.log'),
      File.join(Dir.home, '.aether', 'limen.log')
    ].compact.uniq

    found = candidates.find { |p| File.exist?(p) }
    return found if found
    return CONFIG.log_file_path if follow

    puts "No log file found. Searched:"
    candidates.each { |p| puts "  #{p}" }
    puts "Start the server first with: aethercodex server"
    exit 1
  end

  def print_help
    puts "ÆtherCodex — Console-first Hermetic Programming Oracle"
    puts
    puts "Usage: ÆtherCodex <command> [options]"
    puts
    puts "Commands:"
    puts "  ask \"prompt\"     Ask the oracle a question"
    puts "  server           Start web server (TextMate UI)"
    puts "  logs             Tail the tagged log stream (colored, toggleable)"
    puts "  logs tags        Configure tags: colors + enable/disable"
    puts "  veil             Check, configure, and repair Aether setup"
    puts "  config           Show configuration"
    puts "  context          Show the derived context (root, config, memory DB)"
    puts "  context init     Materialize a .aethercodex config here"
    puts "  context list     List known contexts"
    puts "  task list        List tasks"
    puts "  task show <id>   Show task details"
    puts "  task create      Create a new task"
    puts "  task execute <id> Execute a task"
    puts "  help             Show this help"
    puts
    puts "Examples:"
    puts "  ÆtherCodex ask \"What is the meaning of life?\""
    puts "  echo \"explain this code\" | ÆtherCodex ask"
    puts "  ÆtherCodex logs"
    puts "  ÆtherCodex ask --file app.rb \"Refactor this\""
  end

  def repl_mode
    puts "\e[1m╭─ Delphic Session ──────────────────────────────────╮\e[0m"
    puts "\e[1m│\e[0m  The Pythian oracle awaits your query...             \e[1m│\e[0m"
    puts "\e[1m│\e[0m  type \e[33m/help\e[0m for commands, \e[31mexit\e[0m to depart              \e[1m│\e[0m"
    puts "\e[1m╰──────────────────────────────────────────────────────╯\e[0m"
    puts

    @terminal_stream = TerminalStream.new

    loop do
      print "\e[36mπ\e[0m "
      input = STDIN.gets
      break unless input
      input = input.strip
      break if input == 'exit'
      next if input.empty?

      if input == 'help'
        puts "Commands:"
        puts "  exit          Exit Delphic Session"
        puts "  help          Show this help"
        puts "  /file <path>  Attach a file to the next query"
        puts "  /clear        Clear conversation history"
        puts "  /config       Show current configuration"
        puts "  /context      Show current context"
        puts "  /tools        List available tools"
        puts
        next
      end

      if input.start_with?('/')
        handle_slash_command(input)
        next
      end

      context = Coniunctio.build(history: @history)
      original_stdout = $stdout
      $stdout = File.open('/dev/null', 'w')
      begin
        answer, arts, tool_results = Oracle.divination(input, context, tools: @tools,
                                                        stream: @terminal_stream) do |name, args, tool_ctx|
          @tools.handle(tool: name, args:, context: tool_ctx)
        end
      ensure
        $stdout.close
        $stdout = original_stdout
      end

      puts "\n\e[36m↯ #{answer}\e[0m\n\n"

      @history << { prompt: input, answer: answer, tool_calls: tool_results, created_at: Time.now }
    end
  end

  def handle_slash_command(input)
    case input
    when '/clear'
      @history.clear
      puts "Conversation history cleared."
    when '/config'
      config_mode
    when '/context'
      context_show
    when '/tools'
      @tools.tools.each do |name, tool|
        puts "  #{name}: #{tool.description}"
      end
    when %r{^/file\s+(.+)}
      path = $1.strip
      if File.exist?(path)
        content = File.read(path)
        puts "Attached: #{path} (#{content.lines.count} lines)"
        @history << { prompt: "/file #{path}", answer: "File attached: #{path}\n\n#{content}" }
      else
        puts "File not found: #{path}"
      end
    else
      puts "Unknown command: #{input}"
    end
  end
end

ÆtherCodexCLI.new.run if __FILE__ == $PROGRAM_NAME
