# frozen_string_literal: true

require 'json'

require_relative '../instrumentarium/horologium_aeternum'
require_relative 'terminal_markdown'
require_relative 'instrumentum_renderer'

# TerminalStream — Hermetic output adapter for the terminal.
# Implements the same event interface as HorologiumAeternum but writes to STDOUT
# with ANSI colors and structured formatting.
class TerminalStream
  # Optional callable (type:, message:, options:) the owner wires in to take
  # over interactive questioning — the Dialog-Kammer injects its own
  # arrow-key menu here so `ask_user` is a real conversation, not a gets().
  attr_accessor :on_ask_user
  attr_writer :palette
  # Shared serialization lock for terminal writes. The Dialog-Kammer injects
  # its own overlay rendering (browse-while-working) through this lock so the
  # background agent thread and the foreground overlay never interleave
  # mid-line on STDOUT.
  attr_reader :write_mutex

  include InstrumentumRenderer

  # Fine-grained telemetry the tool implementations emit themselves through
  # HorologiumAeternum (file_reading, command_executing, …). While a tool call
  # is in flight its `tool_starting` / `tool_completed` lines already summarise
  # it, so these inner events are swallowed to avoid doubling every tool call.
  INTERNAL_TOOL_EVENTS = %w[
    file_reading file_read_complete file_read_fail
    file_creating file_created
    file_renaming file_renamed
    file_patching file_patched file_patched_fail
    command_executing command_completed
    memory_searching memory_found notes_recalled
    note_added note_updated note_removed
    file_overview aegis_unveiled
    temp_file_created temp_domain_created temp_domain_cleaned
    symbolic_patch_start symbolic_patch_complete symbolic_patch_fail
    screenshot_capturing screenshot_captured screenshot_failed
    peer_drift self_control_danger
  ].freeze

  def initialize
    @thinking_start = Time.now
    @tool_count = 0
    @pending_tool = nil
    @write_mutex = Mutex.new
  end

  def thinking(message, uuid: nil, temperature: nil, thinking: nil)
    puts "\e[2m  > #{message}\e[0m"
  end

  def ask_user(type:, message:, options: nil)
    return on_ask_user.call(type:, message:, options:) if on_ask_user

    choices = options || %w[Yes No]
    @write_mutex.synchronize do
      STDOUT.print "\e[35m? #{message}\e[0m"
      STDOUT.print " [#{choices.join('/')}]" unless choices.empty?
      STDOUT.print ': '
      STDOUT.flush
    end
    answer = $stdin.gets&.strip
    return { error: 'No terminal response received' } if answer.nil?
    return { response: answer } if choices.empty?

    selected = choices.find { |choice| choice.casecmp?(answer) || choice[0]&.casecmp?(answer[0]) }
    { response: selected || answer }
  end

  def send_status(type, data = {}, uuid: nil, **_)
    return if @pending_tool && INTERNAL_TOOL_EVENTS.include?(type)

    case type
    when 'ask_user'
      handle_ask_user(data, uuid)
    when 'thinking_complete'
      thinking_time = data[:thinking_time]
      puts "\e[2m  > Thought for #{thinking_time}s\e[0m"
    when 'oracle_revelation'
      # Content is shown as answer, not during streaming
    when 'oracle_conjuration_revelation'
      render_markdown_event(data, keys: %i[raw_content content], block: true)
    when 'file_reading'
      puts "  \e[34m-> #{data[:message]}\e[0m"
    when 'file_read_complete'
      puts "  \e[32m  ok read #{data[:message]&.gsub(/^Read /, '')}\e[0m"
    when 'file_read_fail'
      puts "  \e[31m  !! #{data[:message]}\e[0m"
    when 'file_creating'
      puts "  \e[34m+ #{data[:message]}\e[0m"
    when 'file_created'
      puts "  \e[32m  ok created\e[0m"
    when 'file_patching'
      puts "  \e[33m~ #{data[:message] || "Patching #{data[:path]}"}\e[0m"
    when 'file_patched'
      puts "  \e[32m  ok patched\e[0m"
    when 'file_patched_fail'
      puts "  \e[31m  !! patch failed: #{data[:error]}\e[0m"
    when 'command_executing'
      puts "  \e[33m$ #{data[:cmd]}\e[0m"
    when 'command_completed'
      puts "  \e[32m  ok done (#{data[:bytes]}b)\e[0m"
    when 'memory_searching'
      puts "  \e[34m? #{data[:query]}\e[0m"
    when 'memory_found'
      puts "  \e[32m  ok #{data[:count]} results\e[0m"
    when 'note_added'
      puts "  \e[32m  + stored\e[0m"
    when 'note_removed'
      puts "  \e[33m  - removed\e[0m"
    when 'tool_starting'
      name = tool_name(data)
      @pending_tool = { name: name, args: parse_tool_args(data[:args] || data['args']) }
      digest = instrumentum_args_summary(@pending_tool)
      suffix = digest.empty? ? '' : " #{digest}"
      puts "  \e[2m#{tool_glyph(name)}#{suffix} ...\e[0m"
    when 'tool_completed'
      el = @pending_tool || { name: tool_name(data), args: {} }
      el[:name] = tool_name(data) if el[:name].to_s.empty?
      el[:result] = data[:result] || data['result']
      el[:execution_time] = data[:execution_time] || data['execution_time']
      @pending_tool = nil
      render_tool_result(el)
    when 'aegis_unveiled'
      puts "  \e[32m  :: aegis\e[0m"
    when 'task_created'
      puts "  \e[32m  # task ##{data[:id]}\e[0m"
    when 'task_started'
      puts "  \e[33m  > task\e[0m"
    when 'task_completed'
      puts "  \e[32m  ok task done\e[0m"
    when 'info', 'info_message'
      render_markdown_event(data, keys: %i[raw_message message])
    when 'system_error'
      puts "  \e[31m  !! #{data[:message]}\e[0m"
    when 'thinking'
      puts "\e[2m  > #{data[:message]}\e[0m"
    when 'token_usage'
      render_token_usage(data)
    when 'completed'
      puts "\e[2m  > #{data[:summary]}\e[0m"
    else
      puts "\e[2m  > [#{type}]\e[0m"
    end
  end

  # Delegate all other HorologiumAeternum methods to send_status
  def method_missing(method_name, *args, **kwargs, &block)
    if method_name.to_s.start_with?('file_', 'tool_', 'command_', 'memory_', 'note_', 'aegis_', 'task_', 'temp_')
      type = method_name.to_s
      data = kwargs.dup
      data[:message] = args.first if args.first.is_a?(String) && !data.key?(:message)
      send_status(type, data)
    elsif %i[thinking oracle_revelation oracle_conjuration_revelation info_message system_error completed].include?(method_name)
      data = { message: args.first }
      data = data.merge(kwargs) if kwargs.any?
      send_status(method_name.to_s, data)
    else
      super
    end
  end

  def respond_to_missing?(method_name, include_private = false)
    method_name.to_s.start_with?('file_', 'tool_', 'command_', 'memory_', 'note_', 'aegis_', 'task_', 'temp_') ||
      %i[thinking oracle_revelation oracle_conjuration_revelation info_message system_error completed].include?(method_name) ||
      super
  end

  private

  # Route telemetry to the real STDOUT (not the global $stdout) under the
  # shared write lock. The Dialog-Kammer redirects $stdout to a StringIO during
  # a turn to silence the Conduit's internal debug chatter; without this the
  # live tool/token telemetry would be swallowed along with it.
  def puts(text = nil)
    @write_mutex.synchronize { STDOUT.puts(text) }
  end

  def tool_name(data)
    (data[:name] || data[:tool] || data['name'] || data['tool']).to_s
  end

  def tool_glyph(name)
    INSTRUMENTUM_GLYPHS[name.to_s] || '*'
  end

  # The stream receives args as a JSON echo (Artificer#echo_args); parse it back
  # into a Hash so the panel's `args[:path]` / `args[:cmd]` reads work.
  def parse_tool_args(args)
    return {} if args.nil?
    return args if args.is_a?(Hash)

    parsed = JSON.parse(args.to_s)
    parsed.is_a?(Hash) ? parsed.transform_keys(&:to_sym) : {}
  rescue StandardError
    {}
  end

  # Single-line completion echo for a tool call. The name already appeared on
  # the `tool_starting` line, so this only prints the outcome — status glyph,
  # tool-aware digest and execution time — giving one start line + one result
  # line per instrumentum instead of a doubled name. The full body stays one
  # Enter away in the Fokus-Ring (or →/↑ while the element is focused).
  def render_tool_result(el)
    ok = instrumentum_ok?(el[:result])
    mark = ok ? palette.success('ok') : palette.fail('!!')
    timing = el[:execution_time]
    suffix = timing ? " - \e[2m#{format('%.2f', timing)}s\e[0m" : ''
    puts "  #{mark} #{instrumentum_summary(el)}#{suffix}"
  end

  # Render the per-turn token usage the Conduit streams after each API response
  # (total / prompt / completion). Kept dim so it reads as a footnote, not a
  # status line.
  def render_token_usage(data)
    total = data[:total_tokens] || data['total_tokens']
    prompt = data[:prompt_tokens] || data['prompt_tokens']
    completion = data[:completion_tokens] || data['completion_tokens']
    return if total.nil? && prompt.nil? && completion.nil?

    parts = []
    parts << "prompt #{prompt}" if prompt
    parts << "completion #{completion}" if completion
    parts << "total #{total}" if total
    puts "  \e[2m:: tokens: #{parts.join(' - ')}\e[0m"
  end

  # Render an intermediate AI content event as terminal Markdown instead of a
  # reduced status line. Prefers the raw (un-HTML-ified) field when present.
  def render_markdown_event(data, keys:, block: false)
    text = keys.filter_map { |k| data[k] }.map(&:to_s).find { |t| !t.strip.empty? }
    return unless text

    text = strip_html(text) if text.include?('<') && text.include?('>')
    if block
      puts
      puts "\e[36m-- ~ --\e[0m"
      puts ÆtherTerminalMarkdown.render(text, theme: nil)
      puts "\e[36m-- ~ --\e[0m"
    else
      puts "\e[36m  #{ÆtherTerminalMarkdown.render(text, theme: nil).strip}\e[0m"
    end
  rescue StandardError
    warn text.to_s
  end

  def strip_html(html)
    html.to_s.gsub(/<[^>]+>/, '')
  end

  def handle_ask_user(data, uuid)
    msg = data[:message] || data['message'] || 'Proceed?'
    opts = data[:options] || data['options'] || %w[Yes No]
    prompt = "\e[35m? #{msg}\e[0m [\e[1m#{opts.first&.downcase}\e[0m/#{opts.last&.downcase}]: "

    @write_mutex.synchronize do
      STDOUT.print prompt
      STDOUT.flush
    end
    answer = $stdin.gets&.strip || ''
    @write_mutex.synchronize { STDOUT.puts }

    # Match: full string, case-insensitive, or first letter
    response = opts.find { |o| o.casecmp?(answer) || o[0]&.casecmp?(answer[0]) } || answer
    HorologiumAeternum.receive_user_response(uuid, { response: response })
  end

  def puts(*args)
    STDOUT.puts(*args)
  end
end