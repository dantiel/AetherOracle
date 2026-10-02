# frozen_string_literal: true

require 'json'
require 'stringio'
require_relative '../instrumentarium/instrumenta'
require_relative '../instrumentarium/companion_programs'
require_relative 'terminal_stream'
require_relative 'terminal_markdown'
require_relative 'theme'
require_relative 'instrumentum_renderer'
begin
  require 'tty-reader'
  HAVE_TTY_READER = true
rescue LoadError
  HAVE_TTY_READER = false
end
begin
  require_relative 'win_console_input'
  HAVE_WIN_CONSOLE = true
rescue LoadError, StandardError
  HAVE_WIN_CONSOLE = false
end
require_relative 'coniunctio'

begin
  require 'readline'
  HAVE_READLINE = true
rescue LoadError
  HAVE_READLINE = false
end

# On Windows `require 'readline'` resolves to Reline, which caches the console
# input handle once and never refreshes it after external commands are spawned
# (run_command, open_in_editor, ...). A stale handle makes the next
# Readline.readline busy-wait forever, freezing the chamber after one turn.
# Fall back to a plain gets (goes through the OS file descriptor, robust) there.
WINDOWS = !!(RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i)

begin
  require 'tty-prompt'
  require 'pastel'
  HAVE_TTY = true
rescue LoadError
  HAVE_TTY = false
end

# ÆtherChamber -- the Dialog Chamber.
#
# A polymorphic, hermetic conversation room that replaces the old one-shot
# `ask` loop. The chamber is:
#
#   * polymorphic  -- you may *veil* any of the twelve companions (morph) and
#                    the oracle adopts that persona, temperament and toolset;
#   * interactive  -- slash commands, Readline history, live tool telemetry;
#   * hermetically -- the final answer is rendered as terminal Markdown with
#                    Rouge syntax highlighting, so code arrives illuminated.
#
# The base (unveiled) state is the full ÆtherCodex oracle itself.
class ÆtherChamber
  # Namespaced aliases so a practitioner may summon a companion by any of its
  # epithets: the glyph key, the German name, or a descriptive epithet.
  PERSONA_ALIASES = {
    'owl'       => :owl,       'eule'     => :owl,       'athene'    => :owl,
    'kitsune'   => :kitsune,   'fuchs'    => :kitsune,   'fuchsgeist'=> :kitsune,
    'phoenix'   => :phoenix,   'phönix'   => :phoenix,   'bennu'     => :phoenix,
    'ouroboros' => :ouroboros, 'schlange' => :ouroboros, 'jörmungandr'=> :ouroboros,
    'bastet'    => :bastet,    'katze'    => :bastet,    'mafdet'    => :bastet,
    'fenrir'    => :fenrir,    'wolf'     => :fenrir,    'fenrisúlfr'=> :fenrir,
    'undine'    => :undine,    'wasser'   => :undine,    'nymphe'    => :undine,
    'schwan'    => :schwan,    'cygnus'   => :schwan,    'swan'      => :schwan,
    'drache'    => :drache,    'dragon'   => :drache,    'tiamat'    => :drache,
    'corax'     => :corax,     'rabe'     => :corax,     'raben'     => :corax,
    'jindujun'  => :jindujun,  'wolke'    => :jindujun,  'kintōun'   => :jindujun,
    'kintoun'   => :jindujun,  'cloud'    => :jindujun,
    'solomon'   => :solomon,   'salomo'   => :solomon,   'könig'     => :solomon,
    'king'      => :solomon
  }.freeze

  # How many focus-ring entries the log view renders around the focused one.
  FOCUS_LIST_WINDOW = 5

  include InstrumentumRenderer

  # ANSI escape sequences (CSI, OSC terminated by BEL or ST, single-char
  # escapes) -- used to compute visible width without counting colour codes.
  ANSI_SEQUENCE = /\e\[[0-9;?]*[@-~]|\e\][^\a]*(?:\a|\e\\)|\e[@-~]/
  ANSI_TOKEN = /\A(?:\e\[[0-9;?]*[@-~]|\e\][^\a]*(?:\a|\e\\)|\e[@-~])/

  # A pasted-content placeholder in the prompt editor. Multi-line pastes are
  # folded into `[PASTED_CONTENT_1]`, `[PASTED_CONTENT_2]`, ... so the single-line
  # editor stays intact; they expand back into the real text on submit.
  PASTE_TAG_RE = /\[PASTED_CONTENT_\d+\]/

  # Attached "Sigillen" in the prompt. Minted by typing `@` (opens the
  # Sigil-Picker) or by pressing `@` while a Fokus-Ring element is selected.
  #   @owl        summons the companion's voice for exactly one turn
  #   @file:path  attaches a file's contents to the next question
  # Distinct prefixes keep literal @-text (e-mail, ivars) from being misread.
  COMPANION_ALT = COMPANION_PERSONALITIES.keys.map { |k| Regexp.escape(k.to_s) }.join('|').freeze
  COMPANION_SIGIL_RE = /@(#{COMPANION_ALT})\b/
  FILE_SIGIL_RE = /@file:([^\s]+)/

  attr_reader :history, :veiled

  def initialize(tools: Instrumenta, stream: nil, theme: nil)
    @tools = tools
    @stream = stream || TerminalStream.new
    @stream.on_ask_user = ->(type:, message:, options:) { interactive_ask_user(type:, message:, options:) }
    @theme = theme || ENV['AETHER_THEME'] || 'monokai'
    @palette = ÆtherTheme.palette_for(@theme)
    @stream.palette = @palette if @stream.respond_to?(:palette=)
    @history = []
    @veiled = []
    @render_markdown = true
    @highlight = true
    @pending_suggestions = []
    @focusable = []
    @focus_keys = {}
    @line_history = []
    @rendered_lines = 0
    @expanded_focus = {}
    @terminal_size = nil
    @paste_register = []
    @select_menu_lines = 0
    @working_overlay_lines = 0
    @console_mutex = Mutex.new
    @quit = false
  end

  # ------------------------------------------------------------------ run --

  def run
    force_utf8_console
    banner
    Readline.completion_proc = ->(s) { slash_commands.grep(/\A#{Regexp.escape(s)}/) } if HAVE_READLINE

    loop do
      line = read_prompt
      break if line.nil?

      if line.is_a?(Hash)
        activate_focusable(line)
        next
      end

      input = line.strip
      break if %w[exit quit].include?(input)
      next if input.empty?

      if input.start_with?('/')
        handle_slash(input)
        break if @quit
      elsif input.casecmp?('help')
        show_help
      else
        conjure(input)
      end
    end
    release_veil!
    farewell
  end

  private

  # ------------------------------------------------------------- dialogue --

  def conjure(input)
    input, companions = compose_input(input)
    persona = current_persona_prompt
    unless companions.empty?
      glyphs = (@veiled + companions).uniq
      persona = if glyphs.one?
                  CompanionPrograms.build_system_prompt(glyphs.first, COMPANION_PERSONALITIES[glyphs.first][:system_prompt])
                else
                  CompanionPrograms.build_multi_prompt(glyphs)
                end
    end
    context = Coniunctio.build(history: @history, temperature: current_temperature)

    # The agent's turn runs in a background thread -- the groundwork for future
    # background tasks, and the thing that lets the practitioner browse the
    # Fokus-Ring while the agent is still working.
    started = Time.now
    result = {}
    worker = Thread.new { run_divination(input, context, persona, result, tools: @tools) }
    browse_while_working(worker)

    answer = result[:answer]
    tool_results = result[:tool_results]
    return if answer.nil?

    answer, text_suggestions = CompanionPrograms.extract_companion_suggestions(answer)
    emit_answer(answer)
    @history << { prompt: input, answer: answer, tool_calls: tool_results, created_at: Time.now }
    inscribe_chronicle(input, answer, tool_results, started)
    Readline::HISTORY.push(input) if HAVE_READLINE
    emit_companion_interactions(tool_results)
    text_suggestions.each { |s| enqueue_text_suggestion(s) }
    collect_focusables(answer, tool_results: tool_results)
  rescue StandardError => e
    warn "\e[31m!! #{e.class}: #{e.message}\e[0m"
  end

  # Inscribe the completed turn into Mnemosyne's persistent Chronicle. The
  # chamber is its own frontend -- no record flag arrives from Pythia -- so
  # every usage of the oracle is inscribed unconditionally, mirroring the
  # daemon and task-engine interfaces. Inscription never breaks the dialogue.
  def inscribe_chronicle(input, answer, tool_results, started)
    unless defined?(Mnemosyne)
      begin
        require_relative '../mnemosyne/mnemosyne'
      rescue LoadError, StandardError
        return
      end
    end
    Mnemosyne.inscribe({ prompt: input }, answer: answer,
                       tool_calls: tool_results,
                       tool_call_count: Array(tool_results).size,
                       execution_time: (Time.now - started).round(3))
  end

  # Run one Oracle.divination turn in the current thread, capturing the
  # oracle's internal stdout chatter (Conduit debug) into a StringIO so the
  # terminal only shows the stream's own telemetry. Populates `result` with
  # :answer and :tool_results so the caller (in a background thread) can hand
  # the outcome back to the main thread.
  def run_divination(input, context, persona, result, tools:)
    previous_stream = Thread.current[:aether_terminal_stream]
    Thread.current[:aether_terminal_stream] = @stream

    original_stdout = $stdout
    $stdout = StringIO.new
    begin
      answer, _arts, tool_results = Oracle.divination(input, context, tools: tools,
                                                       system_prompt: persona,
                                                       stream: @stream) do |name, args, tool_ctx|
        tools.handle(tool: name, args:, context: tool_ctx)
      end
      result[:answer] = answer
      result[:tool_results] = tool_results
    ensure
      $stdout.close if $stdout != original_stdout
      $stdout = original_stdout
      Thread.current[:aether_terminal_stream] = previous_stream
    end
  end

  # Wait for the background divination thread while polling for Tab/Shift-Tab,
  # so the Fokus-Ring stays browsable during the turn. Windows-only -- the
  # native console probe is non-blocking; elsewhere we fall back to a plain
  # join and keep the prior synchronous behaviour.
  def browse_while_working(worker)
    use_win = win_console_available?
    unless use_win
      worker.join
      return
    end

    begin
      ÆtherWinConsole.begin_raw_input
    rescue StandardError
      ÆtherWinConsole.disable!
      worker.join
      return
    end

    selection = nil
    @working_overlay_lines = 0
    begin
      loop do
        break unless worker.alive?

        # The agent's ask_user menu runs on the worker thread and takes
        # exclusive console ownership (@console_mutex) for the whole
        # interaction. If we cannot grab the lock, hand the console over and
        # stop polling so the two threads never drive ReadConsoleInputW at once.
        break unless @console_mutex.try_lock

        begin
          next unless ÆtherWinConsole.input_ready?

          input = ÆtherWinConsole.next_input
        rescue ÆtherWinConsole::ConsoleInputError
          ÆtherWinConsole.disable!
          break
        ensure
          @console_mutex.unlock if @console_mutex.owned?
        end
        next if input.nil? || input[:kind] != :key

        case input[:action]
        when :tab, :back_tab
          selection = next_tab(selection, input[:action] == :tab ? 1 : -1)
          draw_working_overlay(selection)
        when :up, :right
          if instrumentum_at?(selection)
            @expanded_focus[selection] = true
            draw_working_overlay(selection)
          end
        when :down, :left
          if instrumentum_at?(selection)
            @expanded_focus[selection] = false
            draw_working_overlay(selection)
          end
        when :escape
          selection = nil
          draw_working_overlay(nil)
        when :enter
          clear_working_overlay
          selection = nil
        end
      end
    ensure
      clear_working_overlay
      ÆtherWinConsole.end_raw_input
      worker.join
    end
  end

  # Render the Fokus-Ring preview at the bottom while the agent works -- the
  # same rows the prompt editor uses (minified by default, ^/-> expands), so the
  # browsing experience is identical in both states.
  def draw_working_overlay(selection)
    @stream.write_mutex.synchronize do
      n = [@working_overlay_lines - 1, 0].max
      STDOUT.print "\e[#{n}A" if n.positive?
      STDOUT.print "\r\e[J"

      rows = []
      if selection
        el = tab_positions[selection]
        rows.concat(focus_list_rows(selection, terminal_width))
        rows.concat(instrumentum_preview_rows(el, selection, terminal_width)) if el[:type] == :instrumentum
      else
        rows << "\e[2m... Der Agent arbeitet -- Tab/Shift-Tab browsen, ^/-> aufklappen, Esc ausblenden\e[0m"
      end

      rows.each { |line| STDOUT.print "#{line}\n" }
      @working_overlay_lines = rows.size + 1
      STDOUT.flush
    end
  end

  # Erase the browse-while-working overlay so the answer can render cleanly.
  def clear_working_overlay
    return if @working_overlay_lines.to_i <= 0

    @stream.write_mutex.synchronize do
      n = [@working_overlay_lines - 1, 0].max
      STDOUT.print "\e[#{n}A" if n.positive?
      STDOUT.print "\r\e[J"
      @working_overlay_lines = 0
      STDOUT.flush
    end
  end

  def emit_answer(answer)
    puts
    if @render_markdown
      rendered = ÆtherTerminalMarkdown.render(answer, theme: @highlight ? @theme : nil)
      puts rendered
    else
      puts "\e[36m!! #{answer}\e[0m"
    end
    puts
  end

  # ------------------------------------------------- companion interaction --

  # Render the passive aspects of veiled companions into the terminal: `_say`
  # speaks in the chat flow, `_suggest` floats an actionable bubble, `_commit`
  # acknowledges a memory inscription. Without this, a companion's instruments
  # return data the oracle sees but the practitioner never perceives.
  def emit_companion_interactions(tool_results)
    (tool_results || []).each do |tr|
      name = tr[:name].to_s
      result = tr[:result]
      next unless result.is_a?(Hash)

      key = name.sub(/_(suggest|say|ask|commit)\z/, '')
      case name
      when /_suggest\z/
        emit_companion_suggestion(key, result[:suggestion]) if result[:suggestion].is_a?(Hash)
      when /_say\z/, /_ask\z/
        emit_companion_say(key, result[:say]) if result[:say].is_a?(Hash)
      when /_commit\z/
        emit_companion_commit(key, result)
      end
    end
  end

  def emit_companion_say(key, say)
    persona = COMPANION_PERSONALITIES[key.to_sym]
    glyph = persona&.dig(:glyph) || '*'
    name  = persona&.dig(:name) || key
    body = "  #{glyph} #{name}: #{say[:message]}"
    puts(say[:level].to_s == 'warn' ? @palette.warn(body) : @palette.accent(body))
  end

  def emit_companion_suggestion(key, suggestion)
    persona = COMPANION_PERSONALITIES[key.to_sym]
    glyph = persona&.dig(:glyph) || suggestion[:glyph] || '*'
    name  = suggestion[:name] || persona&.dig(:name) || key
    puts "\e[35m  #{glyph} #{name} schlägt vor: >>#{suggestion[:prompt]}<<\e[0m"
    @pending_suggestions << { key: key.to_sym, prompt: suggestion[:prompt],
                              temperature: suggestion[:temperature],
                              thinking: suggestion[:thinking] }
  end

  def emit_companion_commit(key, result)
    return if result[:error]

    persona = COMPANION_PERSONALITIES[key.to_sym]
    glyph = persona&.dig(:glyph) || result[:glyph] || '*'
    name  = result[:name] || persona&.dig(:name) || key
    puts "\e[32m  #{glyph} #{name}: Gedächtnis gespeichert\e[0m"
    puts "\e[2m     #{result[:summary]}\e[0m" if result[:summary]
    puts "\e[2m     #{result[:facet_note]}\e[0m" if result[:facet_note]
  end

  # Turn a text-block suggestion into the shape `collect_focusables` consumes,
  # resolving the emoji back to a companion key (falling back to the alias map).
  def enqueue_text_suggestion(s)
    key = companion_key_for_glyph(s[:glyph]) || PERSONA_ALIASES[s[:name].to_s.strip.downcase]
    return unless key

    @pending_suggestions << { key: key, prompt: s[:prompt], temperature: nil, thinking: nil }
  end

  def companion_key_for_glyph(glyph)
    COMPANION_PERSONALITIES.each { |k, p| return k if p[:glyph] == glyph }
    nil
  end

  # Execute a floated suggestion as a companion turn: the companion speaks with
  # its own temperament and the full core toolchain (its grant tier rules).
  def run_suggestion_turn(suggestion)
    glyph = suggestion[:key]
    persona = COMPANION_PERSONALITIES[glyph]
    return say_missing_persona(glyph) unless persona

    tools = Instrumenta.select(*CompanionPrograms.tools_for(
      glyph, all_tools: @tools.tools, suggestion_execution: true
    ))
    context = Coniunctio.build(history: @history, temperature: suggestion[:temperature])
    system_prompt = CompanionPrograms.build_system_prompt(glyph, persona[:system_prompt])

    puts "\n\e[35m  #{persona[:glyph]} #{persona[:name]} vollstreckt: #{suggestion[:prompt]}\e[0m"

    result = {}
    run_divination(suggestion[:prompt], context, system_prompt, result, tools: tools)
    answer = result[:answer]
    tool_results = result[:tool_results]
    return if answer.nil?

    answer, text_suggestions = CompanionPrograms.extract_companion_suggestions(answer)
    emit_answer(answer)
    @history << { prompt: suggestion[:prompt], answer: answer, tool_calls: tool_results, created_at: Time.now }
    emit_companion_interactions(tool_results)
    text_suggestions.each { |s| enqueue_text_suggestion(s) }
    collect_focusables(answer, tool_results: tool_results)
  rescue StandardError => e
    warn "\e[31m!! #{e.class}: #{e.message}\e[0m"
  end

  # -------------------------------------------------------- navigation --

  # Accumulate focusable elements into the persistent Fokus-Ring. Files and
  # suggestions come from the just-rendered answer; instrumenta (tool calls)
  # accumulate across the whole session. Nothing is discarded -- the ring only
  # grows, so the practitioner can always tab back to earlier artefacts.
  def collect_focusables(answer, tool_results: nil)
    ÆtherTerminalMarkdown.extract_file_links(answer).each do |fl|
      focus_add({ type: :file }.merge(fl), [:file, fl[:path], fl[:line], fl[:column]])
    end

    @pending_suggestions.each do |s|
      persona = COMPANION_PERSONALITIES[s[:key]]
      focus_add({ type: :suggestion, key: s[:key], glyph: persona&.dig(:glyph),
                  name: persona&.dig(:name), prompt: s[:prompt],
                  temperature: s[:temperature], thinking: s[:thinking] },
                [:suggestion, s[:key], s[:prompt]])
    end
    @pending_suggestions.clear

    Array(tool_results).each do |tr|
      name = tr[:name].to_s
      focus_add({ type: :instrumentum, name: name, result: tr[:result],
                  args: tr[:args], execution_time: tr[:execution_time] },
                [:instrumentum, name, tr[:result].to_s[0, 80]])
    end

    hint_footer
  end

  def focus_add(element, key)
    return if @focus_keys[key]

    @focus_keys[key] = true
    @focusable << element
  end

  def hint_footer
    files = @focusable.count { |e| e[:type] == :file }
    suggs = @focusable.count { |e| e[:type] == :suggestion }
    instr = @focusable.count { |e| e[:type] == :instrumentum }
    parts = []
    parts << "#{files} Datei#{files == 1 ? '' : 'en'}" if files.positive?
    parts << "#{suggs} Vorschl#{suggs == 1 ? 'ag' : 'äge'}" if suggs.positive?
    parts << "#{instr} Instrument#{instr == 1 ? 'um' : 'a'}" if instr.positive?
    parts = ["#{COMPANION_PERSONALITIES.size} Personae - #{slash_commands.size} Befehle"] if parts.empty?
    puts "\e[2m  > #{parts.join(' - ')} -- Tab/Shift-Tab wählt, ^/v (oder ->/<-) klappt Instrumenta auf/zu, Enter öffnet\e[0m"
  end

  # The registered tab positions: the living Fokus-Ring accumulated across the
  # session (files, suggestions, instrumenta). TAB cycles these inline at the
  # prompt -- no separate browser needed.
  def tab_positions
    @focusable
  end

  # Activate a focusable element chosen from the tab ring (Enter at the prompt).
  def activate_focusable(el)
    case el[:type]
    when :file
      open_in_editor(el[:path], line: el[:line], column: el[:column])
    when :suggestion
      run_suggestion_turn(el)
    when :instrumentum
      show_instrumentum(el)
    end
  end

  def tab_label_for(el)
    case el[:type]
    when :file
      suffix = el[:line] ? ":#{el[:line]}#{el[:column] ? ":#{el[:column]}" : ''}" : ''
      "#{el[:glyph] || '::'} #{el[:label] || el[:path]}#{suffix}"
    when :suggestion
      "#{el[:glyph] || '*'} #{el[:name] || el[:key]}: #{el[:prompt]}"
    when :instrumentum
      "#{el[:glyph] || INSTRUMENTUM_GLYPHS[el[:name].to_s] || '*'} #{instrumentum_summary(el)}"
    else
      el[:label] || el[:prompt] || el[:path] || '--'
    end
  end

  def show_instrumentum(el)
    instrumentum_panel(el, max_lines: nil).each { |line| puts line }
  end

  # ---------------------------------------------------- log-view rendering --

  # Terminal dimensions, cached. Falls back to LINES/COLUMNS (24×80) when the
  # console cannot be probed (piped output, tests).
  def terminal_size
    @terminal_size ||= begin
      require 'io/console'
      io = IO.respond_to?(:console) ? IO.console : nil
      ws = io && io.winsize
      ws = nil unless ws.is_a?(Array) && ws[0].to_i.positive? && ws[1].to_i.positive?
      ws || [Integer(ENV['LINES'], exception: false) || 24,
             Integer(ENV['COLUMNS'], exception: false) || 80]
    rescue StandardError
      [Integer(ENV['LINES'], exception: false) || 24,
       Integer(ENV['COLUMNS'], exception: false) || 80]
    end
  end

  def terminal_width
    terminal_size[1]
  end

  def terminal_height
    terminal_size[0]
  end

  def strip_ansi(str)
    str.to_s.gsub(ANSI_SEQUENCE, '')
  end

  # Width of a single character: 2 for emoji/CJK, 1 otherwise.
  def char_width(ch)
    cp = ch.ord
    return 2 if cp >= 0x1F000 && cp <= 0x1FAFF
    return 2 if cp >= 0x2E80 && cp <= 0x9FFF
    return 2 if cp >= 0xAC00 && cp <= 0xD7A3
    return 2 if cp >= 0xF900 && cp <= 0xFAFF
    return 2 if cp >= 0xFE30 && cp <= 0xFE4F
    return 2 if cp >= 0xFF00 && cp <= 0xFF60
    return 2 if cp >= 0xFFE0 && cp <= 0xFFE6

    1
  end

  def display_width(str)
    strip_ansi(str).each_char.sum { |ch| char_width(ch) }
  end

  # Truncate to `width` visible columns, keeping ANSI colour codes intact so no
  # escape sequence is ever cut in half (which would bleed colours into the
  # rest of the screen).
  def truncate_visible(str, width)
    text = str.to_s
    return text if width.nil? || display_width(text) <= width

    out = +''
    visible = 0
    rest = text.dup
    while visible < width && !rest.empty?
      if (m = rest.match(ANSI_TOKEN))
        out << m[0]
        rest = rest[m[0].length..]
        next
      end
      ch = rest[0]
      out << ch
      visible += char_width(ch)
      rest = rest[1..]
    end
    out << "\e[0m"
    out
  end

  # The "log view": a window of the focus ring around the selected index that
  # Tab/Shift-Tab scrolls through.
  def focus_list_rows(selection, width)
    positions = tab_positions
    return [] if positions.empty?

    total = positions.size
    half = FOCUS_LIST_WINDOW / 2
    start = [selection - half, 0].max
    stop = [start + FOCUS_LIST_WINDOW - 1, total - 1].min
    start = [stop - FOCUS_LIST_WINDOW + 1, 0].max

    rows = ["\e[2m- Fokus #{selection + 1}/#{total} -\e[0m"]
    (start..stop).each do |i|
      label = truncate_visible(tab_label_for(positions[i]), width)
      rows << truncate_visible(i == selection ? "\e[1;35m> #{label}\e[0m" : "  #{label}", width)
    end
    rows
  end

  # The focused instrumentum's body, capped so the prompt and the AI content
  # above it never scroll out of view.
  def instrumentum_preview_rows(el, selection, width)
    expanded = @expanded_focus[selection]
    full = instrumentum_panel(el, max_lines: expanded ? nil : MAX_PREVIEW_LINES, minified: !expanded)
    cap = panel_cap
    lines = full.map { |line| truncate_visible(line, width) }
    if lines.size > cap
      extra = lines.size - (cap - 1)
      lines = lines.first(cap - 1)
      lines << "\e[2m... #{extra} weitere Zeilen -- Enter für Vollansicht\e[0m"
    end
    lines
  end

  def panel_cap
    h = terminal_height
    return MAX_PREVIEW_LINES if h.nil? || h < 12

    [h - FOCUS_LIST_WINDOW - 5, 8].max
  end

  def open_in_editor
    editor = ENV['AETHER_EDITOR'] || ENV['EDITOR'] || ENV['VISUAL']
    unless editor && !editor.strip.empty?
      puts "\e[31mKein EDITOR gesetzt (AETHER_EDITOR/EDITOR/VISUAL).\e[0m"
      return
    end

    if editor.match?(/\b(code|cursor|zed|subl|idea|pycharm|webstorm)\b/i)
      target = line ? "#{path}:#{line}#{column ? ":#{column}" : ''}" : path
      system(editor, target)
    else
      args = [editor]
      args << "+#{line}" if line
      args << path
      system(*args)
    end
  end

  def active_glyphs_display
    @veiled.map { |g| COMPANION_PERSONALITIES[g]&.dig(:glyph) || g.to_s }.join
  end

  # -------------------------------------------------------------- persona --

  def current_persona_prompt
    return nil if @veiled.empty?

    if @veiled.one?
      persona = COMPANION_PERSONALITIES[@veiled.first]
      return nil unless persona

      CompanionPrograms.build_system_prompt(@veiled.first, persona[:system_prompt])
    else
      CompanionPrograms.build_multi_prompt(@veiled)
    end
  end

  def current_temperature
    return nil if @veiled.empty?

    # The most recently veiled companion sets the shared temperament.
    CompanionPrograms.temperament(@veiled.last)[:temperature]
  end

  def morph(glyph)
    resolved = glyph.to_s.strip.empty? ? select_persona : resolve_persona(glyph)
    return say_missing_persona(glyph) unless resolved

    if @veiled.include?(resolved)
      persona = COMPANION_PERSONALITIES[resolved]
      puts "\e[2m#{persona[:glyph]} #{persona[:name]}\e[0m ist bereits im Kristall."
      return true
    end

    persona = COMPANION_PERSONALITIES[resolved]
    CompanionPrograms.veil([resolved], persona[:name])
    @veiled << resolved
    temper = CompanionPrograms.temperament(resolved)

    puts "\e[1m#{persona[:glyph]} #{persona[:name]}\e[0m ist in den Kristall getreten."
    puts "   Temperament -- Temperatur #{temper[:temperature] || '--'}, Denken #{temper[:thinking] || '--'}."
    puts "   Aktiv: #{active_glyphs_display}" if @veiled.size > 1
    true
  end

  # Remove one companion (or all, when no argument is given) -- cumulative.
  def unmorph(glyph)
    return release_veil! if glyph.to_s.strip.empty?

    resolved = resolve_persona(glyph)
    return say_missing_persona(glyph) unless resolved
    return false unless @veiled.include?(resolved)

    CompanionPrograms.unveil(resolved)
    @veiled.delete(resolved)
    persona = COMPANION_PERSONALITIES[resolved]
    puts "#{persona[:glyph]} #{persona[:name]} ist aus dem Kristall getreten."
    puts "   Aktiv: #{@veiled.empty? ? '--' : active_glyphs_display}"
    true
  end

  def release_veil!
    return false if @veiled.empty?

    @veiled.each { |g| CompanionPrograms.unveil(g) }
    @veiled.clear
    puts 'Der Schleier fällt -- das Orakel spricht wieder als ÆtherCodex.'
    true
  end

  def resolve_persona(input)
    return nil if input.nil?

    key = input.to_s.strip.downcase
    return nil if key.empty?
    return key.to_sym if COMPANION_PERSONALITIES.key?(key.to_sym)

    # Normalize: strip diacritics minimally for matching, then alias lookup.
    normalized = key.tr('áàâäãåā', 'a').tr('éèêëē', 'e').tr('íìîïī', 'i')
                    .tr('óòôöõøō', 'o').tr('úùûüū', 'u').tr('ñ', 'n').tr('ß', 'ss')
    PERSONA_ALIASES[normalized] || PERSONA_ALIASES[key]
  end

  # Interactive companion selection -- tty-prompt when available, else a
  # numbered list. Both resolve to the same glyph.
  def select_persona
    if HAVE_TTY
      prompt = TTY::Prompt.new(interrupt: :exit)
      prompt.select('Wen rufst du in den Kristall?', per_page: 12) do |menu|
        COMPANION_PERSONALITIES.each do |glyph, p|
          menu.choice "#{p[:glyph]} #{p[:name]}", glyph
        end
      end
    else
      COMPANION_PERSONALITIES.each_with_index do |(glyph, p), i|
        puts "  #{i + 1}. #{p[:glyph]} #{p[:name]} (#{glyph})"
      end
      print 'Wähle eine Nummer: '
      idx = $stdin.gets.to_i - 1
      COMPANION_PERSONALITIES.keys[idx]
    end
  end

  def say_missing_persona(input)
    puts "\e[31mUnbekannter Begleiter: #{input}\e[0m"
    puts "Verfügbar: #{COMPANION_PERSONALITIES.keys.join(', ')}"
    false
  end

  # --------------------------------------------------------------- prompt --

  def prompt_marker
    return "\e[36mπ\e[0m " if @veiled.empty?

    "#{active_glyphs_display} \e[36mπ\e[0m "
  end

  def read_prompt
    return read_prompt_inline if inline_tab_available?

    read_prompt_plain
  end

  # Plain single-line read -- the fallback when neither the native Windows
  # console reader nor TTY::Reader can drive an inline editor.
  def read_prompt_plain
    print prompt_marker
    $stdout.flush
    if HAVE_READLINE && !WINDOWS
      Readline.readline('', true)
    else
      $stdin.gets
    end
  end

  # ------------------------------------------------- interactive ask_user --

  # The oracle's `ask_user` instrument resolves here in the chamber, making the
  # question a real pause: `confirm`/`select` render an arrow-key menu, `prompt`
  # reads a free line. Runs inside `conjure` while `$stdout` is redirected to a
  # StringIO, so every byte is written straight to STDOUT (the constant) rather
  # than the capture buffer.
  def interactive_ask_user(type:, message:, options: nil)
    # Exclusive console ownership: this runs on the agent's background thread
    # while the foreground browse-poll may still read keys. Grab the console
    # mutex so browse_while_working stops polling and the two threads never
    # drive the native console reader concurrently.
    @console_mutex.synchronize { interactive_ask_user_sync(type:, message:, options:) }
  end

  def interactive_ask_user_sync(type:, message:, options: nil)
    type = type.to_s
    opts = (options || %w[Yes No]).map(&:to_s)
    opts = opts.first(2) if type == 'confirm'

    STDOUT.puts
    STDOUT.puts "  #{@palette.accent('?')} #{message}"

    case type
    when 'confirm', 'select'
      return { response: opts.first } if opts.size <= 1

      choice = interactive_select_menu(opts)
      return { error: 'No selection' } if choice.nil?

      { response: choice }
    else
      { response: interactive_line_read }
    end
  end

  # Arrow-key vertical menu over `options`, reusing the chamber's unified input
  # sources (ÆtherWinConsole on Windows, TTY::Reader elsewhere). Enter confirms
  # the highlight, 1-9 jumps directly, Esc/Ctrl-C cancels.
  def interactive_select_menu(options)
    return read_select_plain(options) unless $stdin.tty?

    idx = 0
    @select_menu_lines = 0
    use_win = win_console_available?
    if use_win
      begin
        ÆtherWinConsole.begin_raw_input
      rescue StandardError
        ÆtherWinConsole.disable!
        use_win = false
      end
    end

    begin
      loop do
        redraw_select_menu(options, idx)
        input = use_win ? ÆtherWinConsole.next_input : tty_editor_input
        return nil if input.nil?
        next unless input.is_a?(Hash) && input[:kind] == :key

        case input[:action]
        when :up, :ctrl_up
          idx = (idx - 1) % options.size
        when :down, :ctrl_down
          idx = (idx + 1) % options.size
        when :enter, :return, :right
          return confirm_select_choice(options[idx])
        when :escape, :ctrl_c
          STDOUT.print "\n"
          return nil
        when :literal
          ch = (input[:char] || input[:text]).to_s
          if ch.match?(/\A[1-9]\z/)
            n = ch.to_i - 1
            return confirm_select_choice(options[n]) if n < options.size
          end
        end
      end
    rescue ÆtherWinConsole::ConsoleInputError
      ÆtherWinConsole.disable!
      use_win = false
      ÆtherWinConsole.end_raw_input
      return read_select_plain(options)
    ensure
      ÆtherWinConsole.end_raw_input if use_win
    end
  end

  def confirm_select_choice(choice)
    STDOUT.print "\n"
    STDOUT.puts "  #{@palette.accent('->')} #{choice}"
    choice
  end

  # Numbered fallback for a piped/non-TTY session where arrow keys are
  # meaningless: list the options and read one line.
  def read_select_plain(options)
    options.each_with_index { |opt, i| STDOUT.puts "  #{i + 1}. #{opt}" }
    STDOUT.print "  #{@palette.accent('>')} "
    STDOUT.flush
    line = $stdin.gets&.strip
    return nil if line.nil? || line.empty?

    n = line.to_i
    return options[n - 1] if n.between?(1, options.size)

    options.find { |o| o.casecmp?(line) } || line
  end

  def redraw_select_menu(options, idx)
    n = @select_menu_lines
    STDOUT.print "\e[#{n}A" if n.positive?
    STDOUT.print "\r\e[J"

    rows = options.each_with_index.map do |opt, i|
      marker = i == idx ? @palette.accent('>') : ' '
      label = i == idx ? opt : @palette.dim(opt)
      "   #{marker} #{label}"
    end
    rows << @palette.dim('  ^/v choose - enter confirm - 1-9 jump - esc cancel')
    @select_menu_lines = rows.size
    STDOUT.print rows.join("\n")
    STDOUT.print "\n"
    STDOUT.flush
  end

  def interactive_line_read
    STDOUT.print "  #{@palette.accent('>')} "
    STDOUT.flush
    line = if HAVE_READLINE && !WINDOWS
             Readline.readline('', false)
           else
             # The console may still be raw from the browse-poll. Drop raw mode
             # (ref-counted) so $stdin.gets reads a proper cooked line; the
             # browse_while_working ensure restores the final mode after join.
             ÆtherWinConsole.end_raw_input if win_console_available?
             $stdin.gets
           end
    line&.strip || ''
  end

  def inline_tab_available?
    (win_console_available? || HAVE_TTY_READER) && $stdin.tty?
  end

  def win_console_available?
    WINDOWS && HAVE_WIN_CONSOLE && $stdin.tty? && ÆtherWinConsole.available?
  end

  # Make the Windows console speak UTF-8 so umlauts/emoji survive. The console
  # defaults to CP850 (chcp 850), while Ruby works in UTF-8; without this the
  # prompt editor's UTF-8 buffer renders as mojibake on every redraw. Setting
  # the codepage + stream encodings once, up front, keeps input and output
  # consistent for the whole session.
  def force_utf8_console
    return unless WINDOWS && $stdout.tty?

    if HAVE_WIN_CONSOLE
      begin
        ÆtherWinConsole.force_utf8!
      rescue StandardError
        nil
      end
    end
    Encoding.default_external = Encoding::UTF_8
    Encoding.default_internal = Encoding::UTF_8
    begin
      $stdout.set_encoding(Encoding::UTF_8)
      $stderr.set_encoding(Encoding::UTF_8)
      $stdin.set_encoding(Encoding::UTF_8)
    rescue StandardError
      nil
    end
  end

  # Inline tab cycling at the prompt. Replaces the former /links browser: while
  # the prompt is live, TAB walks forward through the registered Fokus-Ring and
  # Shift-Tab walks backward; Enter activates the highlighted element (opens a
  # file, runs a suggestion, shows a tool result). Any printable key or Esc
  # returns to normal typing; Up/Down recall the line history. Ctrl/Alt+<-/->
  # move by word, Ctrl/Alt+Backspace/Delete delete a word, and a multi-line
  # paste folds into a `[PASTED_CONTENT_n]` tag until submit.
  def read_prompt_inline
    @paste_register = []
    @rendered_lines = 0
    buffer = +''
    cursor = 0
    selection = nil
    hist = nil
    mention = nil

    use_win = win_console_available?
    if use_win
      begin
        ÆtherWinConsole.begin_raw_input
      rescue StandardError
        ÆtherWinConsole.disable!
        use_win = false # console mode probing failed -- fall back to TTY::Reader
      end
    end
    return read_prompt_plain if !use_win && !HAVE_TTY_READER

    @editor_win = use_win
    begin
      loop do
        redraw_inline(buffer, cursor, selection, mention)
        input = next_editor_input
        return nil if input.nil?

        if mention
          mention, buffer, cursor = mention_step(mention, input, buffer, cursor)
          next
        end

        case input[:kind]
        when :paste
          selection = nil
          @paste_register << input[:text]
          tag = "[PASTED_CONTENT_#{@paste_register.size}]"
          buffer.insert(cursor, tag)
          cursor += tag.length
        when :literal
          text = input[:text]
          next if text.empty?

          if text == '@' && selection
            el = tab_positions[selection]
            buffer, cursor = mint_focusable(el, buffer, cursor)
            selection = nil
            next
          end
          selection = nil

          if text == '@'
            buffer.insert(cursor, '@')
            cursor += 1
            mention = { start: cursor - 1, index: 0, query: '' }
            next
          end

          buffer.insert(cursor, text)
          cursor += text.length
        when :key
          case input[:action]
          when :tab, :back_tab
            selection = next_tab(selection, input[:action] == :tab ? 1 : -1)
          when :enter, :return
            selection ? clear_inline_preview : print("\n")
            return finish_prompt(buffer, selection)
          when :escape
            selection = nil
          when :ctrl_c
            print "\n"
            buffer = +''
            cursor = 0
            selection = nil
            hist = nil
          when :ctrl_d
            if buffer.empty?
              print "\n"
              return nil
            else
              selection = nil
              cursor = delete_right(buffer, cursor)
            end
          when :left
            if instrumentum_at?(selection)
              @expanded_focus[selection] = false
            else
              selection = nil
              cursor = cursor_left(buffer, cursor)
            end
          when :right
            if instrumentum_at?(selection)
              @expanded_focus[selection] = true
            else
              selection = nil
              cursor = cursor_right(buffer, cursor)
            end
          when :word_left
            selection = nil
            cursor = word_left(buffer, cursor)
          when :word_right
            selection = nil
            cursor = word_right(buffer, cursor)
          when :home, :ctrl_a, :ctrl_home
            selection = nil
            cursor = 0
          when :end, :ctrl_e, :ctrl_end
            selection = nil
            cursor = buffer.length
          when :backspace
            selection = nil
            cursor = delete_left(buffer, cursor)
          when :delete
            selection = nil
            cursor = delete_right(buffer, cursor)
          when :word_backspace, :ctrl_w
            selection = nil
            cursor = word_delete_left(buffer, cursor)
          when :word_delete
            selection = nil
            cursor = word_delete_right(buffer, cursor)
          when :ctrl_k
            selection = nil
            buffer.slice!(cursor..)
          when :ctrl_u
            selection = nil
            buffer.slice!(0...cursor)
            cursor = 0
          when :literal
            ch = input[:char]
            if ch == '@' && selection
              el = tab_positions[selection]
              buffer, cursor = mint_focusable(el, buffer, cursor)
              selection = nil
              next
            end
            selection = nil

            if ch == '@'
              buffer.insert(cursor, '@')
              cursor += 1
              mention = { start: cursor - 1, index: 0, query: '' }
              next
            end

            buffer.insert(cursor, ch)
            cursor += ch.length
          when :up, :ctrl_up
            if instrumentum_at?(selection)
              @expanded_focus[selection] = true
            else
              selection = nil
              buffer, hist = recall_history(buffer, hist, -1)
              cursor = buffer.length
            end
          when :down, :ctrl_down
            if instrumentum_at?(selection)
              @expanded_focus[selection] = false
            else
              selection = nil
              buffer, hist = recall_history(buffer, hist, +1)
              cursor = buffer.length
            end
          when :page_up, :page_down, :ignore
            # no-op in the prompt editor
          end
        end
      end
    rescue StandardError => e
      raise unless use_win && HAVE_WIN_CONSOLE && e.is_a?(ÆtherWinConsole::ConsoleInputError)

      ÆtherWinConsole.end_raw_input
      ÆtherWinConsole.disable!
      @editor_win = nil
      use_win = false
      clear_inline_preview
      $stderr.puts "!! native console reader unavailable (#{e.message}) -- falling back to line input" if $DEBUG
      return read_prompt_plain
    ensure
      ÆtherWinConsole.end_raw_input if use_win
      @editor_win = nil
    end
  end

  # Resolve the next logical input from the active source (Windows native
  # reader on console Windows, otherwise TTY::Reader).
  def next_editor_input
    return ÆtherWinConsole.next_input if @editor_win

    tty_editor_input
  end

  def tty_editor_input
    @tty_reader ||= TTY::Reader.new(interrupt: :noop)
    @tty_keymap ||= @tty_reader.console.keys
    char = @tty_reader.read_keypress
    return nil if char.nil?

    char = complete_extended_key(char)
    return tty_read_paste if char.start_with?("\e[200~")

    action = @tty_keymap[char]
    action = tty_decode_action(char) if action.nil?
    action = :back_tab if action == :shift_tab

    if action.nil?
      if char == "\x7f" || char == "\b"
        action = :backspace
      elsif char.is_a?(String) && char.match?(/\A[[:print:]]\z/)
        return { kind: :key, action: :literal, char: char }
      else
        return { kind: :key, action: :ignore, char: '' }
      end
    end

    # tty-reader maps the space bar to a named :space action; the prompt
    # editor only understands :literal, so reclassify it as a typed char.
    return { kind: :key, action: :literal, char: char } if action == :space

    { kind: :key, action: action, char: (action == :literal ? char : '') }
  end

  # Recover the second byte of a Windows extended key that tty-reader dropped.
  # On the fallback path (native ÆtherWinConsole unavailable) tty-reader reads
  # via msvcrt `_getch`, and for Shift+Tab / arrows it probes `_kbhit` for the
  # trailing scan code — but `_kbhit` is already 0 after `_getch` consumed the
  # KEY_EVENT, so `read_keypress` returns a lone "\xE0" / "\x00". A blocking
  # `_getch` still yields the cached scan code, so we complete the pair here.
  def complete_extended_key(char)
    return char unless WINDOWS && HAVE_WIN_CONSOLE && (char == "\xE0" || char == "\x00")

    second = ÆtherWinConsole.crt_getch
    return char if second.nil?

    char + [second].pack('C')
  end

  def tty_read_paste
    chunks = []
    loop do
      c = @tty_reader.read_keypress
      break if c.nil? || c.include?("\e[201~")

      chunks << c
    end
    { kind: :paste, text: chunks.join.gsub(/\r\n?/, "\n") }
  end

  # Decode editing escape sequences tty-reader's keymap does not cover.
  def tty_decode_action(char)
    case char
    when "\e[Z", "\e[1;2Z", "\eOZ", "\e[1;2z" then :back_tab
    when "\xE0\x0F", "\x00\x0F" then :back_tab # _getch extended scan code (Shift+Tab)
    when "\e[1;5D", "\eb", "\e[1;3D" then :word_left
    when "\e[1;5C", "\ef", "\e[1;3C" then :word_right
    when "\e[3;5~", "\x17", "\e\x7f", "\e\b" then :word_backspace
    when "\e[3;3~" then :word_delete
    when "\e[1;5A" then :ctrl_up
    when "\e[1;5B" then :ctrl_down
    when "\e[1;5H" then :home
    when "\e[1;5F" then :end
    when "\e[H", "\e[1~", "\eOH" then :home
    when "\e[F", "\e[4~", "\eOF" then :end
    when "\e[3~" then :delete
    end
  end

  def redraw_inline(buffer, cursor, selection, mention = nil)
    n = [@rendered_lines.to_i - 1, 0].max
    print "\e[#{n}A" if n.positive?
    print "\r\e[J"

    width = terminal_width
    rows = []

    if mention
      rows.concat(mention_overlay_rows(mention, width))
    elsif selection
      el = tab_positions[selection]
      rows.concat(focus_list_rows(selection, width))
      rows.concat(instrumentum_preview_rows(el, selection, width)) if el[:type] == :instrumentum
    end

    rows.each { |line| print "#{line}\n" }
    @rendered_lines = rows.size + 1

    print prompt_marker
    avail = [width - display_width(prompt_marker), 1].max
    if mention
      text, col = prompt_line(buffer, cursor, avail)
      print text
      back = display_width(text) - col
      print "\e[#{back}D" if back.positive?
    elsif selection
      print "\e[1;35m#{truncate_visible(tab_label_for(el), avail)}\e[0m"
    else
      text, col = prompt_line(buffer, cursor, avail)
      print text
      back = display_width(text) - col
      print "\e[#{back}D" if back.positive?
    end
    $stdout.flush
  end

  # Colour `[PASTED_CONTENT_n]` tags dim-cyan so they read as placeholders,
  # distinct from the text they will expand into on submit.
  def render_prompt_buffer(buffer)
    buffer.gsub(PASTE_TAG_RE) { |tag| "\e[2;36m#{tag}\e[0m" }
          .gsub(FILE_SIGIL_RE) { |m| "\e[2;36m#{m}\e[0m" }
          .gsub(COMPANION_SIGIL_RE) { |m| "\e[1;35m#{m}\e[0m" }
  end

  # Single-line prompt rendering (no wrapping). When the buffer is wider than
  # the terminal, scroll horizontally so the cursor stays visible; a leading
  # "..." marks text hidden to the left. Returns [text, cursor_col] where
  # cursor_col is the cursor's column within `text` (after the "..."). Keeping
  # the prompt on exactly one physical line is what makes the redraw arithmetic
  # (`\e[nA` + `\r\e[J`) exact -- a wrapped prompt throws the line count off and
  # leaves the previous rows repeating on every keystroke.
  def prompt_line(buffer, cursor, width)
    rendered = render_prompt_buffer(buffer)
    total = display_width(buffer)
    cursor_col = display_width(buffer[0...cursor])
    return [rendered, cursor_col] if total <= width

    start = [cursor_col - (width / 2), 0].max
    start = [start, total - (width - 1)].min
    [slice_visible(rendered, start, width), cursor_col - start + (start.positive? ? 1 : 0)]
  end

  # ANSI-aware horizontal slice of `text`: keep the visible columns from
  # `from_col` for at most `max_width` columns, prefixing "..." when columns on
  # the left were dropped. Colour codes inside the window are preserved.
  def slice_visible(text, from_col, max_width)
    prefix = from_col.positive? ? "\e[2m...\e[0m" : ''
    budget = max_width - (from_col.positive? ? 1 : 0)
    return prefix if budget <= 0

    out = +''
    visible = 0
    emitted = 0
    rest = text.dup
    while !rest.empty? && emitted < budget
      if (m = rest.match(ANSI_TOKEN))
        out << m[0]
        rest = rest[m[0].length..]
        next
      end
      ch = rest[0]
      cw = char_width(ch)
      if visible + cw > from_col
        break if emitted + cw > budget # width-2 char would overrun -- stop clean
        out << ch
        emitted += cw
      end
      visible += cw
      rest = rest[1..]
    end
    out << "\e[0m"
    prefix + out
  end

  def clear_inline_preview
    n = [@rendered_lines.to_i - 1, 0].max
    print "\e[#{n}A" if n.positive?
    print "\r\e[J"
    @rendered_lines = 0
  end

  def instrumentum_at?(index)
    el = index && tab_positions[index]
    el && el[:type] == :instrumentum
  end

  def next_tab(current, delta)
    positions = tab_positions
    return nil if positions.empty?

    return delta.positive? ? 0 : positions.size - 1 if current.nil?

    (current + delta) % positions.size
  end

  def finish_prompt(buffer, selection)
    return tab_positions[selection] if selection

    line = expand_pastes(buffer).rstrip
    @line_history << line unless line.empty? || @line_history.last == line
    line
  end

  # Step through the line history, re-folding any multi-line entry back into a
  # paste tag so the single-line editor never has to render a literal newline.
  def recall_history(buffer, hist, delta)
    buffer, hist = history_step(buffer, hist, delta)
    return [buffer, hist] unless buffer.include?("\n")

    @paste_register << buffer
    [+"[PASTED_CONTENT_#{@paste_register.size}]", hist]
  end

  # Expand `[PASTED_CONTENT_n]` back into the text it stood in for. Unknown
  # tags (the register was cleared) degrade to their literal form.
  def expand_pastes(buffer)
    buffer.gsub(PASTE_TAG_RE) do |tag|
      @paste_register[tag[/\d+/].to_i - 1] || tag
    end
  end

  # ---------------------------------------------------------------- sigils --
  # Attachments minted with `@`. Three kinds share one syntax and one picker:
  # a companion (@owl) summons a voice for one turn, a file (@file:path) attaches
  # its contents, and a suggestion mints its prompt as editable text.

  def mention_sources
    srcs = []
    COMPANION_PERSONALITIES.each do |key, p|
      srcs << { kind: :companion, key: key, glyph: p[:glyph], name: p[:name],
                label: "#{p[:glyph]} #{p[:name]}", chip: "@#{key}",
                filter: "#{key} #{p[:name]}" }
    end
    @focusable.each do |el|
      case el[:type]
      when :file
        srcs << { kind: :file, path: el[:path], label: ":: #{el[:path]}",
                  chip: "@file:#{el[:path]}", filter: el[:path].to_s }
      when :suggestion
        srcs << { kind: :suggestion, key: el[:key], glyph: el[:glyph], name: el[:name],
                  label: "#{el[:glyph] || '*'} #{el[:name] || el[:key]}: #{el[:prompt]}",
                  chip: el[:prompt].to_s.gsub(/\s+/, ' ').strip,
                  filter: "#{el[:name]} #{el[:prompt]}" }
      end
    end
    srcs
  end

  def mention_filter(query)
    q = query.to_s.downcase.strip
    return mention_sources if q.empty?

    mention_sources.select { |s| s[:filter].to_s.downcase.include?(q) }
  end

  def mention_overlay_rows(mention, width)
    results = mention_filter(mention[:query])
    total = results.size
    idx = total.zero? ? 0 : [[mention[:index], total - 1].min, 0].max
    half = FOCUS_LIST_WINDOW / 2
    start = [idx - half, 0].max
    stop  = [start + FOCUS_LIST_WINDOW, total].min
    start = [stop - FOCUS_LIST_WINDOW, 0].max
    head = total.zero? ? "\e[2m  - keine Sigille passt -\e[0m" : "\e[2m  - Sigillen #{idx + 1}/#{total} -\e[0m"
    rows = [head]
    results[start...stop].each_with_index do |el, i|
      at = start + i
      marker = at == idx ? '>' : ' '
      rows << "  #{marker} #{truncate_visible(el[:label].to_s, width - 6)}"
    end
    rows << "\e[2m  - @ Begleiter - @file: Pfad - * Vorschlag - Enter münzt, Esc verwirft -\e[0m"
    rows
  end

  def mention_step(mention, input, buffer, cursor)
    mention[:query] = buffer[(mention[:start] + 1)..cursor].to_s
    results = mention_filter(mention[:query])

    case input[:kind]
    when :key
      case input[:action]
      when :enter, :return
        return finish_mention(mention, results[mention[:index]], buffer, cursor)
      when :escape
        return [nil, buffer, cursor]
      when :ctrl_c
        buffer.slice!(mention[:start]..)
        return [nil, buffer, mention[:start]]
      when :up, :back_tab
        mention[:index] = results.empty? ? 0 : (mention[:index] - 1) % results.size
      when :down, :tab
        mention[:index] = results.empty? ? 0 : (mention[:index] + 1) % results.size
      when :backspace
        if cursor > mention[:start] + 1
          buffer.slice!(cursor - 1)
          cursor -= 1
        else
          return [nil, buffer, cursor]
        end
      when :literal
        ch = input[:char]
        buffer.insert(cursor, ch)
        cursor += ch.length
        mention[:index] = 0
      end
    when :literal
      buffer.insert(cursor, input[:text].to_s)
      cursor += input[:text].to_s.length
      mention[:index] = 0
    when :paste
      buffer.insert(cursor, input[:text].to_s)
      cursor += input[:text].to_s.length
      mention[:index] = 0
    end
    [mention, buffer, cursor]
  end

  def finish_mention(mention, el, buffer, cursor)
    return [nil, buffer, cursor] if el.nil?

    replacement = el[:chip].to_s.gsub("\n", ' ')
    buffer.slice!(mention[:start]...cursor)
    buffer.insert(mention[:start], replacement)
    [nil, buffer, mention[:start] + replacement.length]
  end

  # Pressing `@` while a Fokus-Ring element is selected mints it directly: a
  # file becomes @file:path, a suggestion becomes its editable prompt text.
  def mint_focusable(el, buffer, cursor)
    chip = case el[:type]
           when :file then "@file:#{el[:path]}"
           when :suggestion then el[:prompt].to_s.gsub(/\s+/, ' ').strip
           when :instrumentum then instrumentum_summary(el).to_s.gsub(/\s+/, ' ').strip
           end
    return [buffer, cursor] if chip.nil? || chip.empty?

    buffer.insert(cursor, chip)
    [buffer, cursor + chip.length]
  end

  # Compose the final prompt: strip companion sigils (summoning their voices for
  # this one turn) and file sigils (attaching the files' contents), returning
  # the cleaned text plus the companion glyphs to veil transiently.
  def compose_input(input)
    companions = []
    text = input.gsub(COMPANION_SIGIL_RE) do
      companions << Regexp.last_match(1).to_sym
      ''
    end

    attachments = []
    text = text.gsub(FILE_SIGIL_RE) do
      path = Regexp.last_match(1)
      if File.exist?(path)
        attachments << "-- Anhang #{path} --\n#{File.read(path)}"
      else
        attachments << "-- Anhang #{path} (nicht gefunden) --"
      end
      ''
    end

    text = [text.strip, *attachments].reject { |s| s.empty? }.join("\n\n")
    [text, companions.uniq]
  end

  def history_step(buffer, hist, delta)
    items = @line_history
    return [buffer, hist] if items.empty?

    idx = hist.nil? ? (delta.negative? ? items.size - 1 : nil) : hist + delta
    return [buffer, hist] if idx.nil?
    return [+'', nil] if idx >= items.size
    return [items[0].dup, 0] if idx.negative?

    [items[idx].dup, idx]
  end

  # ------------------------------------------------------------ prompt edit --
  # Tag-aware editing primitives. A pasted-content tag is treated as an atomic
  # unit: the cursor never rests inside it, and Backspace/Delete remove it as
  # a whole rather than one bracket at a time.

  def tag_ranges(buffer)
    ranges = []
    idx = 0
    while (m = buffer.match(PASTE_TAG_RE, idx))
      ranges << [m.begin(0), m.end(0)]
      idx = m.end(0)
    end
    ranges
  end

  def tag_at(buffer, idx)
    tag_ranges(buffer).find { |s, e| idx >= s && idx < e }
  end

  def tag_before(buffer, cursor)
    return nil unless cursor.positive?

    m = buffer[0...cursor].match(/\[PASTED_CONTENT_\d+\]\z/)
    m && [cursor - m[0].length, m[0].length]
  end

  def tag_after(buffer, cursor)
    m = buffer[cursor..].to_s.match(/\A\[PASTED_CONTENT_\d+\]/)
    m && [cursor, m[0].length]
  end

  def cursor_left(buffer, cursor)
    return 0 if cursor <= 0

    nc = cursor - 1
    t = tag_at(buffer, nc)
    t ? t[0] : nc
  end

  def cursor_right(buffer, cursor)
    return cursor if cursor >= buffer.length

    t = tag_at(buffer, cursor)
    t ? t[1] : cursor + 1
  end

  def delete_left(buffer, cursor)
    if (t = tag_before(buffer, cursor))
      buffer.slice!(t[0], t[1])
      t[0]
    elsif cursor.positive?
      buffer.slice!(cursor - 1)
      cursor - 1
    else
      cursor
    end
  end

  def delete_right(buffer, cursor)
    if (t = tag_after(buffer, cursor))
      buffer.slice!(t[0], t[1])
      cursor
    elsif cursor < buffer.length
      buffer.slice!(cursor)
      cursor
    else
      cursor
    end
  end

  # Start positions of each word. A word begins at the line start, after a
  # space, or at a tag boundary (so a tag glued to text still navigates as its
  # own unit).
  def word_starts(buffer)
    tags = tag_ranges(buffer)
    starts = [0]
    (0...buffer.length).each do |i|
      next if buffer[i].match?(/\s/)

      prev = i.zero? ? nil : buffer[i - 1]
      starts << i if prev.nil? || prev.match?(/\s/) || tags.any? { |s, e| s == i || e == i }
    end
    starts.uniq.sort
  end

  # End positions of each word (one past the last character).
  def word_ends(buffer)
    tags = tag_ranges(buffer)
    ends = []
    (0...buffer.length).each do |i|
      next if buffer[i].match?(/\s/)

      nxt = i + 1
      nxt_ch = nxt < buffer.length ? buffer[nxt] : nil
      ends << nxt if nxt_ch.nil? || nxt_ch.match?(/\s/) || tags.any? { |s, e| s == nxt || e == nxt }
    end
    ends.uniq.sort
  end

  def word_left(buffer, cursor)
    return 0 if cursor <= 0

    word_starts(buffer).reverse.find { |p| p < cursor } || 0
  end

  def word_right(buffer, cursor)
    return buffer.length if cursor >= buffer.length

    word_ends(buffer).find { |e| e > cursor } || buffer.length
  end

  def word_delete_left(buffer, cursor)
    target = word_left(buffer, cursor)
    buffer.slice!(target...cursor)
    target
  end

  def word_delete_right(buffer, cursor)
    target = word_right(buffer, cursor)
    buffer.slice!(cursor...target)
    cursor
  end

  def slash_commands
    %w[/help /morph /unmorph /personae /file /clear /history /config /context /tools
       /markdown /highlight /theme /exit]
  end

  # ---------------------------------------------------------------- slash --

  def handle_slash(input)
    cmd, _, arg = input.partition(/\s+/)
    arg = arg.strip

    case cmd
    when '/help'                    then show_help
    when '/morph', '/veil'          then morph(arg)
    when '/unmorph', '/release'     then unmorph(arg)
    when '/personae', '/companions' then list_personae
    when '/file'                    then attach_file(arg)
    when '/clear'                   then clear_history
    when '/history'                 then show_history(arg)
    when '/config'                  then config_summary
    when '/context'                 then context_summary
    when '/tools'                   then list_tools
    when '/markdown'                then toggle_markdown
    when '/highlight'               then toggle_highlight
    when '/theme'                   then set_theme(arg)
    when '/exit', '/quit' then @quit = true
    else
      puts "Unbekannter Befehl: #{cmd}"
    end
  end

  def show_help
    puts <<~HELP

      \e[1mDialog-Kammer -- Befehle\e[0m
        /morph <begleiter>   Begleiter hinzufügen (kumulativ -- mehrere zugleich)
        /unmorph [begleiter] Einen Begleiter entfernen (ohne Argument: alle)
        /personae            Alle zwölf Begleiter auflisten
        /file <pfad>         Datei an die nächste Frage heften
        @begleiter           Stimme für genau eine Runde beschwören (z. B. @owl, @kitsune)
        @file:<pfad>         Datei an die nächste Frage heften
        @                    Sigillen-Picker öffnen: Enter münzt, Esc verwirft
        Tab / Shift-Tab      Fokus-Positionen durchlaufen (Dateien - Vorschläge - Instrumenta), Enter öffnet
        /clear              Gesprächsverlauf löschen
        /history [n|flags]  Verlauf zeigen (Sitzung + Chronik; --session/--chronicle)
        /config             Konfiguration zeigen
        /context            Abgeleiteten Kontext zeigen
        /tools              Verfügbare Werkzeuge listen
        /markdown           Markdown-Rendering an/aus
        /highlight          Syntax-Highlighting an/aus
        /theme <name>       Highlight-Theme wählen (argonaut - aethernaut - aethernight - aetherlight)
        /exit, exit         Die Kammer verlassen

      \e[2mBegleiter: owl kitsune phoenix ouroboros bastet fenrir undine schwan
                 drache corax jindujun solomon\e[0m
    HELP
  end

  def list_personae
    puts "\e[1mDie zwölf Begleiter\e[0m"
    COMPANION_PERSONALITIES.each do |glyph, p|
      mark = @veiled.include?(glyph) ? ' *' : '  '
      temper = CompanionPrograms.temperament(glyph)
      puts "#{mark} #{p[:glyph]} #{p[:name].ljust(28)} #{glyph.to_s.ljust(10)} " \
           "T:#{temper[:temperature]} D:#{temper[:thinking]}"
    end
    puts "\e[2m  * = aktuell entschleiert\e[0m"
  end

  def attach_file(path)
    if path.empty?
      puts 'Verwendung: /file <pfad>'
      return
    end
    unless File.exist?(path)
      puts "Datei nicht gefunden: #{path}"
      return
    end

    content = File.read(path)
    puts "Angeheftet: #{path} (#{content.lines.count} Zeilen)"
    @history << { prompt: "/file #{path}", answer: "File attached: #{path}\n\n#{content}" }
  end

  def clear_history
    @history.clear
    Readline::HISTORY.clear if HAVE_READLINE
    puts 'Gesprächsverlauf gelöscht.'
  end

  def show_history(arg)
    session_only = false
    chronicle_only = false
    limit = 7
    arg.to_s.split.each do |a|
      case a
      when '--session', '-s'   then session_only = true
      when '--chronicle', '-c' then chronicle_only = true
      when /\A\d+\z/           then limit = a.to_i
      end
    end

    render_session_history unless chronicle_only
    render_chronicle(limit)  unless session_only
  end

  def render_session_history
    if @history.empty?
      puts "\e[1mSitzung (in-memory)\e[0m -- noch kein Verlauf"
      return
    end
    puts "\e[1mSitzung (in-memory)\e[0m -- #{@history.size} Einträge"
    @history.each_with_index do |h, i|
      tools = Array(h[:tool_calls]).size
      stamp = h[:created_at].is_a?(Time) ? h[:created_at].strftime('%H:%M:%S') : h[:created_at].to_s
      puts "-- #{i + 1}. #{stamp}  (#{tools} tools)"
      puts "π #{h[:prompt].to_s.strip}"
      ans = h[:answer].to_s.strip
      puts ans.empty? ? '   (keine Antwort)' : ans
      puts
    end
  end

  def render_chronicle(limit)
    unless defined?(Mnemosyne)
      begin
        require_relative '../mnemosyne/mnemosyne'
      rescue LoadError, StandardError
        puts 'Chronik nicht verfügbar.'
        return
      end
    end
    entries = Mnemosyne.fetch_history(limit: limit)
    if entries.nil? || entries.empty?
      puts "\e[1mChronik (persistent)\e[0m -- keine Einträge"
      return
    end
    puts "\e[1mChronik (persistent)\e[0m -- letzte #{entries.size}"
    entries.each do |e|
      stamp = e[:created_at] || e[:timestamp]
      puts "-- #{stamp}  (#{e[:tool_call_count].to_i} tools)"
      puts "π #{e[:prompt].to_s.strip}"
      ans = e[:answer].to_s.strip
      puts ans.empty? ? '   (keine Antwort)' : ans
      puts
    end
  end

  def config_summary
    puts "Model: #{CONFIG.model}  -  API: #{CONFIG.api_type}  -  Flash: #{CONFIG.fast_model}"
  end

  def context_summary
    puts "Projekt: #{CONFIG.project_name}  -  Root: #{CONFIG.project_root}"
    puts "Memory-DB: #{CONFIG.memory_db_path}"
  end

  def list_tools
    @tools.tools.each do |name, tool|
      puts "  #{name}: #{tool.description}"
    end
  end

  def toggle_markdown
    @render_markdown = !@render_markdown
    puts "Markdown-Rendering #{@render_markdown ? 'an' : 'aus'}."
  end

  def toggle_highlight
    @highlight = !@highlight
    puts "Syntax-Highlighting #{@highlight ? 'an' : 'aus'}."
  end

  def set_theme(name)
    if name.empty?
      puts "Verfügbare Themes: #{available_theme_names.join(', ')}"
      return
    end
    if theme_available?(name)
      @theme = name.to_s.downcase
      @palette = ÆtherTheme.palette_for(@theme)
      puts "Theme gewählt: #{@theme}"
    else
      puts "Unbekanntes Theme: #{name}"
      puts "Verfügbar: #{available_theme_names.join(', ')}"
    end
  end

  # Rouge built-ins plus every fundus theme in resources/Themes.
  def available_theme_names
    (ÆtherTerminalMarkdown::THEMES.keys + ÆtherTheme.names).uniq.sort
  end

  def theme_available?(name)
    key = name.to_s.downcase
    ÆtherTerminalMarkdown::THEMES.key?(key) || !ÆtherTheme.resolve(key).nil?
  end

  # -------------------------------------------------------------- framing --

  def banner
    glyph = @veiled.empty? ? '*' : active_glyphs_display
    puts "\e[1m+- Dialog-Kammer -- ÆtherCodex -----------------------------+\e[0m"
    puts "\e[1m|\e[0m  #{glyph}  Der Kristall ist gestimmt; zwölf Stimmen harren.    \e[1m|\e[0m"
    puts "\e[1m|\e[0m  \e[2m/morph\e[0m ruft sie, \e[2m/unmorph\e[0m entlässt sie, \e[2mexit\e[0m geht.      \e[1m|\e[0m"
    puts "\e[1m+----------------------------------------------------------+\e[0m"
    puts
  end

  def farewell
    puts "\e[2m  :: Der Schleier schließt sich. Möge der Äther dich tragen.\e[0m"
  end
end