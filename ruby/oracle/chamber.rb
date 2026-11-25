# frozen_string_literal: true

require 'json'
require 'stringio'
require_relative '../instrumentarium/instrumenta'
require_relative '../instrumentarium/companion_programs'
require_relative 'terminal_stream'
require_relative 'terminal_markdown'
require_relative 'theme'
require_relative 'instrumentum_renderer'
require_relative 'token_ledger'
require_relative 'ui'
require_relative 'shell'
require_relative '../../lib/aetheroracle/version' unless defined?(AetherOracle::VERSION)
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
require_relative 'mouse_backend'
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
  # Raised inside the worker thread to unwind an in-flight turn on Ctrl+C.
  # Subclasses Exception (not StandardError) so Oracle.divination's broad
  # `rescue StandardError` cannot swallow it; the chamber rescues it explicitly.
  class TurnAborted < Exception; end

  # Thread-local gate the Oracle loop consults at every step boundary
  # (`Thread.current[:pause_gate]&.arm(messages)&.wait`). The chamber uses it to
  # weave a word typed while the agent works straight into the live messages, so
  # the amendment reaches the next API call instead of queueing behind the turn.
  class TurnGate
    def initialize
      @mutex = Mutex.new
      @messages = nil
      @pending = []
    end

    # The worker hands over the live messages at each boundary. An amendment
    # woven in before the first boundary (the turn was still assembling) is
    # flushed here, so it is never lost to the gap before the first step.
    def arm(messages)
      @mutex.synchronize do
        @messages = messages
        @pending.each { |text| messages << { role: 'user', content: text } }
        @pending.clear
      end
      self
    end

    # Weave the practitioner's word into the running chapter. Lands immediately
    # once the worker has reached a boundary, otherwise waits in the pending
    # queue until the next `arm`. Never blocks.
    def amend(text)
      @mutex.synchronize do
        if @messages
          @messages << { role: 'user', content: text.to_s }
        else
          @pending << text.to_s
        end
      end
      true
    end

    # The chamber never holds the turn, so the boundary wait is a no-op. It
    # exists because the Oracle loop chains `arm(...).wait` unconditionally.
    def wait
      :released
    end
  end

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
  PASTE_TAG_RE = /\[PASTED_CONTENT_\d+(?: · \d+ Zeichen)?\]/

  # Attached "Sigillen" in the prompt. Minted by typing `@` (opens the
  # Sigil-Picker) or by pressing `@` while a Fokus-Ring element is selected.
  #   @owl        summons the companion's voice for exactly one turn
  #   @file:path  attaches a file's contents to the next question
  # Distinct prefixes keep literal @-text (e-mail, ivars) from being misread.
  COMPANION_ALT = COMPANION_PERSONALITIES.keys.map { |k| Regexp.escape(k.to_s) }.join('|').freeze
  COMPANION_SIGIL_RE = /@(#{COMPANION_ALT})\b/
  FILE_SIGIL_RE = /@file:([^\s]+)/

  # Inline markdown spans highlighted in the prompt editor. `prefix` is the
  # number of raw characters of the opening marker; `group` names the capture
  # carrying the visible text. group-0 patterns (sigils / paste tags) are
  # coloured in place -- their markers are not rewritten -- while markdown
  # spans drop their markers and colour only the visible text.
  INLINE_PATTERNS = [
    { re: PASTE_TAG_RE,          group: 0, prefix: 0, style: :paste },
    { re: FILE_SIGIL_RE,         group: 0, prefix: 0, style: :file_sigil },
    { re: COMPANION_SIGIL_RE,    group: 0, prefix: 0, style: :companion_sigil },
    { re: /`([^`\n]+)`/,         group: 1, prefix: 1, style: :code },
    { re: /\*\*([^*\n]+)\*\*/,   group: 1, prefix: 2, style: :bold },
    { re: /~~([^~\n]+)~~/,       group: 1, prefix: 2, style: :strike },
    { re: /(?<!\*)\*([^*\n]+)\*(?!\*)/, group: 1, prefix: 1, style: :italic },
    { re: /\[([^\]\n]+)\]\(([^)\n]+)\)/, group: 1, prefix: 1, style: :link }
  ].freeze

  STYLE_CODES = {
    code: "\e[36m",
    bold: "\e[1m",
    strike: "\e[9m",
    italic: "\e[3m",
    link: "\e[4;34m",
    paste: "\e[2;36m",
    file_sigil: "\e[2;36m",
    companion_sigil: "\e[1;35m"
  }.freeze

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
    @mouse = true
    @pending_suggestions = []
    @focusable = []
    @focus_keys = {}
    @line_history = []
    @rendered_lines = 0
    @cursor_row = 0
    @click_overlay_rows = 0
    @text_sel = nil
    @drag_anchor = nil
    @expanded_focus = {}
    @terminal_size = nil
    @paste_register = []
    @select_menu_lines = 0
    @working_overlay_lines = 0
    @console_mutex = Mutex.new
    @stdout_mutex = Mutex.new
    @quit = false
    @pending_turn = nil
    @prefill = nil
    @session_has_content = false
  end

  # ------------------------------------------------------------------ run --

  def run
    force_utf8_console
    TokenLedger.reset_session!
    register_session
    banner
    puts TokenLedger.opening_line
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

      if input.start_with?('$')
        enter_shell(input)
        next
      end

      if input.start_with?('/')
        handle_slash(input)
        break if @quit
      elsif input.casecmp?('help')
        show_help
      else
        conjure(input)
        break if @quit
      end
    end
    release_session_on_exit
    release_veil!
    farewell
  end

  private

  # Register this chamber as a session in the shared Aegis ledger, so a sibling
  # session (daemon, another chamber) in the same project sees it. The Aegis
  # writes that happen each turn keep the roster row fresh via save_aegis_state.
  def register_session
    return unless Mnemosyne.respond_to?(:register_session)

    sid = Mnemosyne::Hydra.generate_id
    Mnemosyne.current_session_id = sid
    Mnemosyne.register_session(session_id: sid, label: "Chamber·#{Process.pid}",
                               role: 'chamber', project: CONFIG.project_root,
                               pid: Process.pid)
  rescue StandardError
    nil
  end

  # Persist the mid-flight resume_state of an aborted/failed turn onto the
  # session row so a later /resume-session can restore it and /continue can
  # pick the turn back up (not just reload its history). Best-effort.
  def persist_pending_turn(input, persona, resume_state)
    return unless defined?(Mnemosyne) && Mnemosyne.respond_to?(:save_session_state)
    sid = Mnemosyne.current_session_id
    return if sid.nil? || sid.to_s.empty?

    @session_has_content = true
    Mnemosyne.save_session_state(session_id: sid, state: {
      pending_prompt: input,
      persona: persona,
      resume_state: resume_state || {}
    })
  rescue StandardError
    nil
  end

  # A cleanly finished turn leaves nothing in flight: clear the durable snapshot.
  def clear_persisted_turn
    return unless defined?(Mnemosyne) && Mnemosyne.respond_to?(:save_session_state)
    sid = Mnemosyne.current_session_id
    return if sid.nil? || sid.to_s.empty?

    Mnemosyne.save_session_state(session_id: sid, state: nil)
  rescue StandardError
    nil
  end

  # Rebuild @pending_turn from a persisted unfinished turn so /continue resumes
  # the interrupted computation. Returns the restored turn or nil.
  def restore_pending_turn(state)
    return nil unless state.is_a?(Hash)

    prompt = state[:pending_prompt] || state['pending_prompt']

    # A chamber-wrapped snapshot (abort/error) carries pending_prompt plus a
    # nested resume_state. A session *ended mid-turn* (exit/kill) instead left
    # the Oracle's raw crash-resume snapshot ({messages:, tool_results:, arts:,
    # answer:}) — no wrapper. Recover the last user prompt from that snapshot so
    # /continue still resumes the interrupted turn, not just its history.
    if prompt.nil? || prompt.to_s.strip.empty?
      messages = state[:messages] || state['messages']
      return nil unless messages.is_a?(Array) && !messages.empty?

      prompt = last_user_prompt(messages)
      return nil if prompt.nil? || prompt.to_s.strip.empty?

      @pending_turn = { prompt: prompt, persona: nil, error: nil, aborted: true,
                        resume_state: state }
      return @pending_turn
    end

    persona = state[:persona] || state['persona']
    resume_state = state[:resume_state] || state['resume_state'] || {}
    @pending_turn = { prompt: prompt.to_s, persona: persona, error: nil, aborted: true,
                      resume_state: resume_state }
  end

  # The most recent non-empty user message in a crash-resume transcript — the
  # prompt that was in flight when the turn died. Tool results live under
  # `role: 'tool'`, so a `user` role is a genuine prompt (or, in rare retry
  # paths, a system-injected continuation nudge).
  def last_user_prompt(messages)
    Array(messages).reverse_each do |m|
      m = m.transform_keys(&:to_sym) if m.respond_to?(:transform_keys)
      next unless m[:role].to_s == 'user'

      txt = extract_message_text(m[:content])
      return txt unless txt.to_s.strip.empty?
    end
    nil
  end

  # On exit, an empty session (no completed turn, no unfinished state) is a
  # phantom head — delete it rather than leave another stale row. A session that
  # produced anything is closed (kept resumable).
  def release_session_on_exit
    return unless defined?(Mnemosyne)
    sid = Mnemosyne.current_session_id
    return if sid.nil? || sid.to_s.empty?

    if @session_has_content
      Mnemosyne.close_session if Mnemosyne.respond_to?(:close_session)
    elsif Mnemosyne.respond_to?(:kick_session)
      Mnemosyne.kick_session(session_id: sid)
    end
  rescue StandardError
    nil
  end

  # ------------------------------------------------------------- dialogue --

  def conjure(input)
    persona = nil
    input, companions = compose_input(input)
    persona = build_persona(companions)
    perform_turn(input, persona)
  rescue StandardError => e
    @pending_turn = { prompt: input, persona: persona, error: e }
    warn "\e[31m!! #{e.class}: #{e.message}\e[0m"
    puts @palette.dim('  Zug abgebrochen — /continue setzt fort.')
  end

  # Compose the active persona from the permanently veiled companions plus any
  # single-turn @-mentions resolved by compose_input.
  def build_persona(companions)
    return current_persona_prompt if companions.empty?

    glyphs = (@veiled + companions).uniq
    if glyphs.one?
      CompanionPrograms.build_system_prompt(glyphs.first, COMPANION_PERSONALITIES[glyphs.first][:system_prompt])
    else
      CompanionPrograms.build_multi_prompt(glyphs)
    end
  end

  # Run one full turn. Returns true on success, false when the turn produced no
  # answer (the practitioner can /continue). Any exception raised here in the
  # main thread propagates to the caller, which records it as @pending_turn.
  def perform_turn(input, persona, resume_state: nil)
    flash_aegis_intent(input)
    context = Coniunctio.build(history: @history, temperature: current_temperature)

    # The agent's turn runs in a background thread -- the groundwork for future
    # background tasks, and the thing that lets the practitioner browse the
    # Fokus-Ring while the agent is still working.
    started = Time.now
    result = {}
    gate = TurnGate.new
    worker = Thread.new do
      Thread.current[:pause_gate] = gate
      run_divination(input, context, persona, result, tools: @tools, resume_state: resume_state)
    ensure
      Thread.current[:pause_gate] = nil
    end
    browse_while_working(worker, gate)

    if result[:aborted]
      @pending_turn = { prompt: input, persona: persona, error: nil, aborted: true,
                        resume_state: result[:pause_state] }
      persist_pending_turn(input, persona, result[:pause_state])
      puts
      puts @palette.warn('  Zug abgebrochen.')
      puts @palette.dim('  /edit bearbeitet die letzte Eingabe, /continue setzt fort.')
      return false
    end

    answer = result[:answer]
    tool_results = result[:tool_results]

    if answer.nil? || failed_answer?(answer)
      err = result[:error] || build_turn_error(answer)
      @pending_turn = { prompt: input, persona: persona, error: err,
                        resume_state: result[:pause_state] }
      persist_pending_turn(input, persona, result[:pause_state])
      if err
        warn "\e[31m!! #{err.class}: #{err.message}\e[0m"
      else
        warn "\e[31m!! Zug lieferte keine Antwort\e[0m"
      end
      puts @palette.dim('  /continue setzt den Zug fort.')
      return false
    end

    @pending_turn = nil
    @session_has_content = true
    clear_persisted_turn
    answer, text_suggestions = CompanionPrograms.extract_companion_suggestions(answer)
    emit_answer(answer)
    @history << { prompt: input, answer: answer, tool_calls: tool_results, created_at: Time.now }
    inscribe_chronicle(input, answer, tool_results, started)
    flash_aegis_sediment(input, answer)
    Readline::HISTORY.push(input) if HAVE_READLINE
    emit_companion_interactions(tool_results)
    text_suggestions.each { |s| enqueue_text_suggestion(s) }
    collect_focusables(answer, tool_results: tool_results)
    true
  end

  # Resume the most recent turn that finished prematurely (worker error, empty
  # answer, or main-thread failure). If the failed attempt saved a mid-flight
  # checkpoint (messages + accumulated tool calls), it is handed back to the
  # oracle as `resume_state`, so /continue keeps every tool call already made and
  # only re-issues the step that failed — a true continuation, not a restart.
  def continue_turn(remark = nil)
    turn = @pending_turn
    if turn.nil? || turn[:prompt].to_s.strip.empty?
      puts 'Kein unvollendeter Zug zum Fortsetzen.'
      return
    end
    resume_state = turn[:resume_state] || turn[:pause_state]

    # Optional practitioner remark ("/continue <bemerkung>") — woven in as an
    # extra user message so the resumed turn can be steered mid-flight. With a
    # mid-flight checkpoint the remark is appended to the saved transcript;
    # without one it is folded into the re-submitted prompt.
    remark = remark.to_s.strip
    unless remark.empty?
      if resume_state
        msgs = resume_state[:messages] || resume_state['messages']
        if msgs.is_a?(Array)
          resume_state = resume_state.dup
          msgs = msgs.dup
          msgs << { role: 'user', content: remark }
          resume_state[:messages] = msgs
          resume_state['messages'] = msgs
        end
      else
        prompt = turn[:prompt].to_s.strip
        turn = turn.merge(prompt: "#{prompt}\n\n#{remark}")
      end
    end

    if resume_state
      done = Array(resume_state[:tool_results]).size
      puts @palette.dim("  → Fortsetzen: #{turn[:prompt].to_s.strip[0, 60]} (#{done} Werkzeugaufruf(e) werden wiederaufgenommen)")
    else
      puts @palette.dim("  → Fortsetzen: #{turn[:prompt].to_s.strip[0, 60]}")
    end
    perform_turn(turn[:prompt], turn[:persona], resume_state: resume_state)
  rescue StandardError => e
    @pending_turn = turn.merge(error: e)
    warn "\e[31m!! #{e.class}: #{e.message}\e[0m"
    puts @palette.dim('  /continue erneut versuchen.')
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

  # Flash-Aegis: distill the prompt into a transient pre-turn intent (off unless
  # `flash: { intent: true }`). Best-effort — never breaks the dialogue.
  def flash_aegis_intent(input)
    return unless defined?(Mnemosyne) && Mnemosyne.respond_to?(:flash_aegis_intent)

    Mnemosyne.flash_aegis_intent(input)
  rescue StandardError
    nil
  end

  # Flash-Aegis: digest the completed turn into a new course (on by default;
  # `flash: { sediment: false }` disables). Best-effort.
  def flash_aegis_sediment(input, answer)
    return unless defined?(Mnemosyne) && Mnemosyne.respond_to?(:flash_aegis_sediment)

    Mnemosyne.flash_aegis_sediment(input, answer)
  rescue StandardError
    nil
  end

  # Run one Oracle.divination turn in the current thread, capturing the
  # oracle's internal stdout chatter (Conduit debug) into a StringIO so the
  # terminal only shows the stream's own telemetry. Populates `result` with
  # :answer and :tool_results so the caller (in a background thread) can hand
  # the outcome back to the main thread.
  def run_divination(input, context, persona, result, tools:, resume_state: nil)
    previous_stream = Thread.current[:aether_terminal_stream]
    Thread.current[:aether_terminal_stream] = @stream

    original_stdout = $stdout
    capture = StringIO.new
    @stdout_mutex.synchronize { $stdout = capture }
    begin
      answer, arts, tool_results = Oracle.divination(input, context, tools: tools,
                                                     system_prompt: persona,
                                                     stream: @stream,
                                                     resume_state: resume_state) do |name, args, tool_ctx|
        tools.handle(tool: name, args:, context: tool_ctx)
      end
      result[:answer] = answer
      result[:tool_results] = tool_results
      result[:error] ||= turn_error_from_arts(arts)
    rescue TurnAborted
      result[:aborted] = true
    rescue StandardError => e
      result[:error] = e
    ensure
      # Capture the oracle's mid-flight checkpoint (messages + accumulated tool
      # calls) so /continue can resume this exact turn instead of restarting it.
      result[:pause_state] = Thread.current[:pause_state]
      @stdout_mutex.synchronize do
        capture.close unless capture.closed?
        $stdout = original_stdout
      end
      Thread.current[:aether_terminal_stream] = previous_stream
    end
  end

  # A turn that ends in one of these sentinels did not actually complete: the
  # conduit returns "❌ API Error: …" / "❌ Connection lost …" for HTTP and
  # network failures, and Oracle.divination surfaces hard errors as the literal
  # "<<empty>>". Treating them as real answers would clear @pending_turn and
  # pollute @history, leaving /continue with nothing to resume.
  def failed_answer?(answer)
    return false if answer.nil?

    stripped = answer.to_s.strip
    return true if '<<empty>>' == stripped

    stripped.start_with?('❌ API Error') || stripped.start_with?('❌ Connection lost')
  end

  # Extract a descriptive error from a failed-answer sentinel so the
  # practitioner sees *why* the turn died instead of a bare "no answer".
  def build_turn_error(answer)
    stripped = answer.to_s.strip
    return nil if stripped.empty? || '<<empty>>' == stripped

    RuntimeError.new(stripped.sub(/\A❌\s*/, ''))
  end

  # Oracle.divination packs its failure reason into the arts hash (e.g.
  # `{ error: "Divination failed: …" }`) and returns "<<empty>>" as the answer.
  # Surface that reason as a real exception so the caller can show it.
  def turn_error_from_arts(arts)
    return nil unless arts.is_a?(Hash) && arts[:error]

    arts[:error].is_a?(Exception) ? arts[:error] : RuntimeError.new(arts[:error].to_s)
  end

  # Wait for the background divination thread while polling for keystrokes, so
  # the chamber stays open (type to amend, Enter to dispatch, Tab to browse)
  # during the turn. Ctrl+C aborts the turn (raises TurnAborted in the worker).
  # Prefers the native Windows console reader (non-blocking ReadConsoleInputW);
  # otherwise polls TTY::Reader non-blockingly, and only as a last resort blocks
  # on a SIGINT-aware join.
  def browse_while_working(worker, gate = nil)
    use_win = win_console_available?
    unless use_win
      return browse_while_working_tty(worker, gate) if HAVE_TTY_READER && $stdin.tty?

      return join_with_interrupt(worker)
    end

    begin
      ÆtherWinConsole.begin_raw_input
    rescue StandardError
      ÆtherWinConsole.disable!
      worker.join
      return
    end

    selection = nil
    buffer = +''
    @paste_register = []
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
          # No input yet: yield the CPU instead of busy-spinning on
          # WaitForSingleObject for the whole turn. A tool call keeps this loop
          # alive for seconds; spinning at 100% starves the worker and hammers
          # the console input handle that the prompt editor depends on.
          unless ÆtherWinConsole.input_ready?
            sleep 0.01
            next
          end

          input = ÆtherWinConsole.next_input
        rescue ÆtherWinConsole::ConsoleInputError
          # A transient read error (e.g. a spawned child process momentarily
          # disturbing the console input queue) must not degrade the rest of the
          # session. Mark the reader for a re-probe (`disable!` drops the
          # `@available == true` cache) and stop polling for this turn only;
          # `available?` re-verifies GetConsoleMode on the next prompt.
          ÆtherWinConsole.disable!
          break
        ensure
          @console_mutex.unlock if @console_mutex.owned?
        end
        next if input.nil?

        # Typed text and pastes collect into a working prompt line; Enter weaves
        # them into the running turn (or executes a command) instead of waiting
        # for the answer to finish.
        if input[:kind] == :paste
          selection = nil
          text = input[:text].to_s
          @paste_register << text
          buffer << paste_tag(@paste_register.size, text)
          draw_working_overlay(selection, buffer)
          next
        end

        if input[:kind] == :literal
          selection = nil
          buffer << input[:text].to_s
          draw_working_overlay(selection, buffer)
          next
        end

        next unless input[:kind] == :key

        if input[:action] == :literal
          selection = nil
          buffer << input[:char].to_s
          draw_working_overlay(selection, buffer)
          next
        end

        case input[:action]
        when :ctrl_c
          worker.raise(TurnAborted) if worker.alive?
          break
        when :tab, :back_tab
          selection = next_tab(selection, input[:action] == :tab ? 1 : -1)
          draw_working_overlay(selection, buffer)
        when :up, :right
          if instrumentum_at?(selection)
            @expanded_focus[selection] = true
            draw_working_overlay(selection, buffer)
          end
        when :down, :left
          if instrumentum_at?(selection)
            @expanded_focus[selection] = false
            draw_working_overlay(selection, buffer)
          end
        when :escape
          selection = nil
          draw_working_overlay(nil, buffer)
        when :backspace
          unless buffer.empty?
            delete_left(buffer, buffer.length)
            draw_working_overlay(selection, buffer)
          end
        when :word_backspace, :ctrl_w
          unless buffer.empty?
            word_delete_left(buffer, buffer.length)
            draw_working_overlay(selection, buffer)
          end
        when :enter
          submitted = expand_pastes(buffer).dup
          buffer.clear
          clear_working_overlay
          dispatch_working_input(submitted, gate)
          selection = nil
          draw_working_overlay(selection, buffer)
        end
      end
    ensure
      clear_working_overlay
      worker.join
      ÆtherWinConsole.end_raw_input
      ÆtherWinConsole.reset!
    end
  end

  # TTY::Reader fallback for browse-while-working: poll keypresses non-blockingly
  # so the practitioner can still type amendments and run commands while the
  # agent works on platforms where the native Windows console reader is
  # unavailable (mintty / MSYS2 / macOS / Linux). Same key vocabulary as the
  # native path; mouse/Fokus-Ring expansion stays minimal (Tab browsing only).
  def browse_while_working_tty(worker, gate = nil)
    @tty_reader ||= TTY::Reader.new(interrupt: :noop)
    @tty_keymap ||= @tty_reader.console.keys

    selection = nil
    buffer = +''
    @paste_register = []
    @working_overlay_lines = 0
    aborted = false

    # Between polls the terminal is back in cooked mode, where Ctrl+C is a
    # signal rather than a keypress -- trap it so a stray Ctrl+C cannot kill the
    # chamber. Inside a poll the raw-mode read surfaces Ctrl+C as the "\x03"
    # key, handled below; both paths unwind the worker via TurnAborted.
    previous = Signal.trap('INT') do
      aborted = true
      worker.raise(TurnAborted) if worker.alive?
    end

    begin
      loop do
        break unless worker.alive?

        char = @tty_reader.read_keypress(nonblock: true)
        if char.nil?
          sleep 0.03
          next
        end

        input = decode_tty_char(char)
        next if input.nil?

        if input[:kind] == :paste
          selection = nil
          @paste_register << input[:text]
          buffer << paste_tag(@paste_register.size, input[:text])
          draw_working_overlay(selection, buffer)
          next
        end

        next unless input[:kind] == :key

        case input[:action]
        when :ctrl_c
          worker.raise(TurnAborted) if worker.alive?
          aborted = true
          break
        when :literal
          selection = nil
          buffer << input[:char].to_s
          draw_working_overlay(selection, buffer)
        when :tab, :back_tab
          selection = next_tab(selection, input[:action] == :tab ? 1 : -1)
          draw_working_overlay(selection, buffer)
        when :escape
          selection = nil
          draw_working_overlay(selection, buffer)
        when :backspace
          delete_left(buffer, buffer.length) unless buffer.empty?
          draw_working_overlay(selection, buffer)
        when :word_backspace, :ctrl_w
          word_delete_left(buffer, buffer.length) unless buffer.empty?
          draw_working_overlay(selection, buffer)
        when :enter, :return, :newline
          submitted = expand_pastes(buffer).dup
          buffer.clear
          clear_working_overlay
          dispatch_working_input(submitted, gate)
          draw_working_overlay(selection, buffer)
        end
      end
    rescue Interrupt, Errno::EINTR
      # A SIGINT delivered while a blocking read was in flight; the trap above
      # already armed the abort -- fall through to the teardown.
      aborted = true
    ensure
      clear_working_overlay
      worker.join
      Signal.trap('INT', previous || 'DEFAULT')
    end

    aborted ? :aborted : nil
  rescue ArgumentError
    # Signal.trap unavailable (restricted platform): join plainly.
    clear_working_overlay
    worker.join
    nil
  end

  # Non-Windows fallback: block on the worker but honour Ctrl+C by unwinding the
  # in-flight divination. The editor's TTY::Reader is not active during the turn,
  # so a transient SIGINT trap is safe here.
  def join_with_interrupt(worker)
    aborted = false
    previous = Signal.trap('INT') do
      aborted = true
      worker.raise(TurnAborted) if worker.alive?
    end
    begin
      worker.join
    ensure
      Signal.trap('INT', previous || 'DEFAULT')
    end
    aborted ? :aborted : nil
  rescue ArgumentError
    # Signal.trap unavailable (non-main thread / restricted platform): join plainly.
    worker.join
    nil
  end

  # Render the Fokus-Ring preview at the bottom while the agent works -- the
  # same rows the prompt editor uses (minified by default, ^/-> expands), so the
  # browsing experience is identical in both states.
  def draw_working_overlay(selection, buffer = nil)
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
        rows << "\e[2m... Der Agent arbeitet -- tippen und Enter: Wort einweben · Tab/Shift-Tab browsen · Esc ausblenden\e[0m"
      end

      if buffer && !buffer.empty?
        styled = tokenize_inline(buffer).map { |t| render_token(t) }.join
        rows << truncate_visible(prompt_marker + styled + "\e[2m▌\e[0m", terminal_width)
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

  # Mint a pasted-content placeholder that also shows the paste's length, so a
  # multi-line paste reads `[PASTED_CONTENT_1 · 412 Zeichen]` in the single-line
  # editor instead of an opaque counter.
  def paste_tag(index, text)
    "[PASTED_CONTENT_#{index} · #{text.to_s.length} Zeichen]"
  end

  # Dispatch a line typed while the agent was working. Slash commands and `$`
  # shell pipelines execute in place (the chamber stays open); any other text is
  # woven into the running turn as an amendment -- it lands after the next tool
  # call, not queued behind the turn.
  def dispatch_working_input(line, gate)
    input = line.to_s.strip
    return if input.empty?

    if input.start_with?('$')
      with_terminal_stdout { (@shell ||= ÆtherShell.new(palette: @palette)).execute(input[1..].to_s.strip) }
    elsif input.start_with?('/')
      cmd = input.partition(/\s+/).first
      unless %w[/help /aegis /personae /companions /history /config /context /cost
                /markdown /highlight /mouse /clear].include?(cmd)
        STDOUT.print "#{@palette.dim('  !')} #{cmd} ist während des laufenden Zugs nicht verfügbar.\n"
        return
      end
      with_terminal_stdout { handle_slash(input) }
    else
      if gate&.amend(input)
        confirm = input.gsub(/\s+/, ' ').strip
        w = terminal_width
        confirm = truncate_visible(confirm, w - 20) if w && w > 20
        STDOUT.print "#{@palette.dim('  ↪ Einweben:')} #{confirm}\n"
      end
    end
  rescue StandardError => e
    STDOUT.print "#{@palette.warn('  !!')} #{e.class}: #{e.message}\n"
  end

  # Run a block with `$stdout` pointed back at the terminal. The worker thread
  # swaps the *global* $stdout to a StringIO for the whole turn (to silence the
  # Conduit's debug chatter), which would swallow slash-command output typed
  # mid-turn. Both swaps serialize on @stdout_mutex so the worker's teardown can
  # never close the StringIO beneath a concurrent dispatch.
  def with_terminal_stdout
    @stdout_mutex.synchronize do
      previous = $stdout
      $stdout = STDOUT
      begin
        @stream.write_mutex.synchronize { yield }
      ensure
        $stdout = previous unless previous.closed?
      end
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
    return [] if selection.nil? || positions.empty?

    start, stop = focus_window(selection)
    rows = ["\e[2m- Fokus #{selection + 1}/#{positions.size} -\e[0m"]
    (start..stop).each do |i|
      label = truncate_visible(tab_label_for(positions[i]), width)
      rows << truncate_visible(i == selection ? "\e[1;35m> #{label}\e[0m" : "  #{label}", width)
    end
    rows
  end

  # The [start, stop] index window (inclusive) focus_list_rows renders around
  # `selection`. Shared by the click resolver so it can map a clicked row back
  # to the focusable index it represents.
  def focus_window(selection)
    total = tab_positions.size
    return [nil, nil] if selection.nil? || total.zero?

    half = FOCUS_LIST_WINDOW / 2
    start = [selection - half, 0].max
    stop = [start + FOCUS_LIST_WINDOW - 1, total - 1].min
    start = [stop - FOCUS_LIST_WINDOW + 1, 0].max
    [start, stop]
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
    if glyph.to_s.strip.empty?
      selected = select_personae
      return false unless selected
      return apply_veil_set(selected)
    end

    resolved = resolve_persona(glyph)
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

  # Interactive companion selection -- checkbox-style multi-select. With
  # TTY::Prompt the practitioner checks/unchecks companions (space toggles,
  # enter commits); the current veil is pre-checked. Without it, a numbered
  # toggle loop reconciles the same way. Returns the final glyph set.
  def select_personae
    if HAVE_TTY
      order = COMPANION_PERSONALITIES.keys
      prompt = TTY::Prompt.new(interrupt: :exit)
      result = prompt.multi_select('Welche Begleiter? (Leertaste = an/ab, Enter = fertig)', per_page: 12) do |menu|
        COMPANION_PERSONALITIES.each do |glyph, p|
          menu.choice "#{p[:glyph]} #{p[:name]}", glyph
        end
        defaults = @veiled.map { |g| order.index(g) + 1 }.compact
        menu.default(*defaults) unless defaults.empty?
      end
      Array(result).compact.map(&:to_sym)
    else
      set = @veiled.dup
      loop do
        COMPANION_PERSONALITIES.each_with_index do |(glyph, p), i|
          mark = set.include?(glyph) ? '[x]' : '[ ]'
          puts "  #{format('%2d', i + 1)}. #{mark} #{p[:glyph]} #{p[:name]}"
        end
        print 'Nummern umschalten, Leer = fertig: '
        input = $stdin.gets.to_s.strip
        break if input.empty?
        input.split(/[\s,]+/).each do |tok|
          glyph = COMPANION_PERSONALITIES.keys[tok.to_i - 1]
          next unless glyph
          set.include?(glyph) ? set.delete(glyph) : set << glyph
        end
      end
      set
    end
  end

  # Reconcile the veil to an exact glyph set (checkbox panel submit): unveil
  # the deselected, veil the newly selected, keep the rest untouched.
  def apply_veil_set(selected)
    selected = Array(selected).compact.map(&:to_sym).uniq
    added   = selected - @veiled
    removed = @veiled - selected

    removed.each { |g| CompanionPrograms.unveil(g) }
    added.each   { |g| CompanionPrograms.veil([g], COMPANION_PERSONALITIES[g]&.dig(:name)) }
    @veiled = selected

    if @veiled.empty?
      puts 'Der Schleier fällt -- das Orakel spricht wieder als ÆtherCodex.'
    else
      added.each do |g|
        p = COMPANION_PERSONALITIES[g]
        puts "\e[1m#{p[:glyph]} #{p[:name]}\e[0m ist in den Kristall getreten." if p
      end
      removed.each do |g|
        p = COMPANION_PERSONALITIES[g]
        puts "#{p[:glyph]} #{p[:name]} ist aus dem Kristall getreten." if p
      end
      puts "   Aktiv: #{active_glyphs_display}"
    end
    true
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

  # ---------------------------------------------------------------- shell --

  # The `$` prefix transmorphs the π-prompt into ÆtherShell: a Nushell-like,
  # structured-data CLI. The single `@shell` instance persists across entries so
  # cwd, variables and history survive the round-trip back to the oracle.
  def enter_shell(initial_input)
    shell_input = initial_input[1..].to_s.strip
    @shell ||= ÆtherShell.new(palette: @palette)
    @shell.run(shell_input.empty? ? nil : shell_input)
  end

  def read_prompt
    prefill = @prefill
    @prefill = nil
    return read_prompt_inline(initial: prefill) if inline_tab_available?

    read_prompt_plain(prefill)
  end

  # Plain single-line read -- the fallback when neither the native Windows
  # console reader nor TTY::Reader can drive an inline editor.
  def read_prompt_plain(prefill = nil)
    if HAVE_READLINE && !WINDOWS && prefill && !prefill.empty?
      Readline.pre_input_hook = lambda do
        Readline.insert_text(prefill)
        Readline.redisplay
      end
      line = Readline.readline(prompt_marker, true)
      Readline.pre_input_hook = nil
      return line
    end

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
    when 'confirm'
      return { response: opts.first } if opts.size <= 1

      choice = interactive_select_menu(opts, allow_custom: false, single_key: true)
      return { error: 'No selection' } if choice.nil?

      { response: choice }
    when 'select'
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
  # the highlight, 1-9 jumps directly, Esc/Ctrl-C cancels. Typing any other
  # printable character opens a free-text "other" line so the practitioner may
  # specify a value beyond the offered options; Enter confirms it, Esc returns
  # to the menu.
  def interactive_select_menu(options, allow_custom: true, single_key: false)
    return read_select_plain(options, allow_custom:, single_key:) unless $stdin.tty?

    idx = 0
    custom = nil
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
        custom.nil? ? redraw_select_menu(options, idx, allow_custom:, single_key:) : redraw_select_custom(options, custom)
        input = use_win ? ÆtherWinConsole.next_input : tty_editor_input
        return nil if input.nil?
        next unless input.is_a?(Hash)

        if custom.nil?
          case input[:kind]
          when :key
            case input[:action]
            when :up, :ctrl_up then idx = (idx - 1) % options.size
            when :down, :ctrl_down then idx = (idx + 1) % options.size
            when :enter, :return, :right then return confirm_select_choice(options[idx])
            when :escape, :ctrl_c
              STDOUT.print "\n"
              return nil
            when :literal
              ch = (input[:char] || '').to_s
              # Windows scan-code leak: when the native reader is unavailable
              # the arrow cluster can surface as bare scan codes (H=up, P=down,
              # K=left, M=right). Re-map them so the menu navigates instead of
              # swallowing them as free-text "other" input. Only the first char
              # is interpreted here — once a custom answer has begun, letters
              # type literally.
              case ch
              when 'H' then idx = (idx - 1) % options.size
              when 'P' then idx = (idx + 1) % options.size
              when 'M' then return confirm_select_choice(options[idx])
              when 'K' then nil # left — no vertical effect in this menu
              else
                if ch.match?(/\A[1-9]\z/)
                  n = ch.to_i - 1
                  return confirm_select_choice(options[n]) if n < options.size
                elsif single_key && (match = single_key_match(options, ch))
                  return confirm_select_choice(match)
                elsif allow_custom && ch.match?(/\A[[:graph:]]\z/)
                  custom = +ch
                end
              end
            end
          when :literal, :paste
            text = input[:text].to_s.gsub(/\r?\n/, ' ')
            next if text.empty?
            if text.match?(/\A[1-9]\z/) && text.to_i <= options.size
              return confirm_select_choice(options[text.to_i - 1])
            elsif single_key && (match = single_key_match(options, text))
              return confirm_select_choice(match)
            elsif allow_custom
              custom = text
            end
          end
        else
          case input[:kind]
          when :key
            case input[:action]
            when :enter, :return
              return confirm_select_choice(custom) unless custom.empty?
            when :escape
              custom = nil
            when :ctrl_c
              STDOUT.print "\n"
              return nil
            when :backspace
              custom = custom[0...-1]
              custom = nil if custom.empty?
            when :literal
              custom << (input[:char] || '').to_s
            end
          when :literal, :paste
            text = input[:text].to_s.gsub(/\r?\n/, ' ')
            custom << text unless text.empty?
          end
        end
      end
    rescue ÆtherWinConsole::ConsoleInputError
      ÆtherWinConsole.disable!
      use_win = false
      ÆtherWinConsole.end_raw_input
      return read_select_plain(options, allow_custom:, single_key:)
    ensure
      ÆtherWinConsole.end_raw_input if use_win
    end
  end

  # Render the free-text "other" entry beneath a dimmed option list while the
  # practitioner types a custom answer, reusing the same erase-and-redraw frame
  # as redraw_select_menu.
  def redraw_select_custom(options, custom)
    n = @select_menu_lines
    STDOUT.print "\e[#{n}A" if n.positive?
    STDOUT.print "\r\e[J"

    rows = options.map { |opt| "    #{@palette.dim(opt)}" }
    rows << "   #{@palette.accent('other')} #{custom}#{@palette.accent('_')}"
    rows << @palette.dim('  type - enter confirm - esc back to options')
    @select_menu_lines = rows.size
    STDOUT.print rows.join("\n")
    STDOUT.print "\n"
    STDOUT.flush
  end

  def confirm_select_choice(choice)
    STDOUT.print "\n"
    STDOUT.puts "  #{@palette.accent('->')} #{choice}"
    choice
  end

  # Map a single keystroke to an option by its first letter (case-insensitive).
  # Returns nil unless exactly one option matches, so ambiguous labels never
  # trigger an accidental jump.
  def single_key_match(options, ch)
    return nil if ch.nil? || ch.empty?
    down = ch[0].downcase
    matches = options.select { |o| !o.empty? && o[0].downcase == down }
    matches.size == 1 ? matches.first : nil
  end

  # Numbered fallback for a piped/non-TTY session where arrow keys are
  # meaningless: list the options and read one line. A number picks the option,
  # anything else is returned verbatim as the practitioner's custom answer.
  def read_select_plain(options, allow_custom: true, single_key: false)
    options.each_with_index { |opt, i| STDOUT.puts "  #{i + 1}. #{opt}" }
    if single_key
      letters = options.map { |o| o[0]&.downcase }.compact
      STDOUT.puts @palette.dim("  (number or #{letters.join('/')} to select)")
    else
      STDOUT.puts @palette.dim('  (number to select, or type your own)')
    end
    STDOUT.print "  #{@palette.accent('>')} "
    STDOUT.flush
    line = $stdin.gets&.strip
    return nil if line.nil? || line.empty?

    n = line.to_i
    return options[n - 1] if n.between?(1, options.size)

    return single_key_match(options, line) if single_key

    options.find { |o| o.casecmp?(line) } || (allow_custom ? line : nil)
  end

  def redraw_select_menu(options, idx, allow_custom: true, single_key: false)
    n = @select_menu_lines
    STDOUT.print "\e[#{n}A" if n.positive?
    STDOUT.print "\r\e[J"

    rows = options.each_with_index.map do |opt, i|
      marker = i == idx ? @palette.accent('>') : ' '
      label = i == idx ? opt : @palette.dim(opt)
      "   #{marker} #{label}"
    end
    rows << @palette.dim(select_menu_hint(options, allow_custom:, single_key:))
    @select_menu_lines = rows.size
    STDOUT.print rows.join("\n")
    STDOUT.print "\n"
    STDOUT.flush
  end

  def select_menu_hint(options, allow_custom:, single_key:)
    parts = ['^/v choose', 'enter confirm']
    if single_key
      letters = options.map { |o| o[0]&.downcase }.compact
      parts << "#{letters.join('/')} shortcut" unless letters.empty?
    elsif allow_custom
      parts << 'type for other'
    end
    parts << 'esc cancel'
    parts.join(' - ')
  end

  # Fullscreen, scrolling selector for long rosters (the session chooser).
  # Swaps to the alternate screen buffer, paints a title plus a scrollable
  # window over the options, and returns the chosen label (nil on Esc). Arrow
  # keys auto-scroll the window; PgUp/PgDn/Home/End jump; Enter confirms.
  def fullscreen_select_menu(options, allow_custom: true, single_key: false, title: nil)
    return read_select_plain(options, allow_custom:, single_key:) unless $stdin.tty?
    return interactive_select_menu(options, allow_custom:, single_key:) if options.size <= 8

    idx = 0
    top = 0
    choice = nil
    fallback = false
    use_win = win_console_available?
    if use_win
      begin
        ÆtherWinConsole.begin_raw_input
      rescue StandardError
        ÆtherWinConsole.disable!
        use_win = false
      end
    end

    STDOUT.print "\e[?1049h\e[2J\e[H"
    begin
      loop do
        rows = [terminal_height.to_i - 3, 1].max
        top = idx if idx < top
        top = idx - rows + 1 if idx >= top + rows
        redraw_fullscreen_menu(options, idx, top, rows, title:)
        input = use_win ? ÆtherWinConsole.next_input : tty_editor_input
        break if input.nil?
        next unless input.is_a?(Hash)

        if input[:kind] == :key
          case input[:action]
          when :up, :ctrl_up            then idx = (idx - 1) % options.size
          when :down, :ctrl_down        then idx = (idx + 1) % options.size
          when :page_up                 then idx = [idx - rows, 0].max
          when :page_down               then idx = [idx + rows, options.size - 1].min
          when :home, :ctrl_home        then idx = 0
          when :end, :ctrl_end          then idx = options.size - 1
          when :enter, :return, :right  then choice = options[idx]; break
          when :escape, :ctrl_c         then choice = nil; break
          when :literal
            ch = (input[:char] || '').to_s
            if ch.match?(/\A[1-9]\z/)
              n = ch.to_i - 1
              choice = options[n] if n < options.size
              break if choice
            elsif single_key && (match = single_key_match(options, ch))
              choice = match
              break
            elsif allow_custom && ch.match?(/\A[[:graph:]]\z/)
              choice = ch
              break
            end
          end
        elsif input[:kind] == :literal || input[:kind] == :paste
          text = input[:text].to_s.gsub(/\r?\n/, ' ')
          next if text.empty?
          if text.match?(/\A[1-9]\z/) && text.to_i <= options.size
            choice = options[text.to_i - 1]
            break
          elsif single_key && (match = single_key_match(options, text))
            choice = match
            break
          elsif allow_custom
            choice = text
            break
          end
        end
      end
    rescue ÆtherWinConsole::ConsoleInputError
      ÆtherWinConsole.disable!
      use_win = false
      ÆtherWinConsole.end_raw_input
      fallback = true
    ensure
      STDOUT.print "\e[?1049l"
      ÆtherWinConsole.end_raw_input if use_win
    end

    return read_select_plain(options, allow_custom:, single_key:) if fallback

    if choice.nil?
      STDOUT.print "\n"
    else
      STDOUT.puts "  #{@palette.accent('->')} #{choice}"
    end
    choice
  end

  # Paint one window of the fullscreen selector: title, the visible slice of
  # options (cursor-marked), padding to a stable height, and a scroll hint.
  def redraw_fullscreen_menu(options, idx, top, rows, title:)
    out = +''
    unless title.nil? || title.to_s.empty?
      out << "  #{@palette.accent(title.to_s)}\n\n"
    end

    visible = options[top, rows] || []
    visible.each_with_index do |opt, i|
      real = top + i
      marker = real == idx ? @palette.accent('>') : ' '
      label = real == idx ? opt : @palette.dim(opt)
      out << "   #{marker} #{truncate_visible(label, [terminal_width - 6, 20].max)}\n"
    end
    (visible.size...rows).each { out << "\n" }

    if options.size > rows
      pos = "#{top + 1}-#{[top + rows, options.size].min}/#{options.size}"
      out << @palette.dim("  #{pos} · ↑↓/PgUp/PgDn scrollen · Enter fortsetzen · Esc abbrechen")
    else
      out << @palette.dim('  ↑↓ wählen · Enter fortsetzen · Esc abbrechen')
    end

    STDOUT.print "\e[H\e[J"
    STDOUT.print out
    STDOUT.flush
  end

  def interactive_line_read
    STDOUT.print "  #{@palette.accent('>')} "
    STDOUT.flush
    line = if HAVE_READLINE && !WINDOWS
             Readline.readline('', false)
           else
             # The console may still be raw from the browse-poll. Drop to the
             # pristine cooked mode so $stdin.gets reads a proper line; the
             # browse_while_working ensure joins first and then restores the
             # final mode, so the two threads never fight over the console.
             ÆtherWinConsole.reset! if win_console_available?
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
        # Turn on ANSI/VT processing so the fullscreen selector's alternate
        # screen buffer (\e[?1049h) actually swaps on classic conhost (cmd.exe);
        # Windows Terminal already implies it, cmd.exe does not.
        ÆtherWinConsole.enable_virtual_terminal!
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
  def read_prompt_inline(initial: nil)
    @paste_register = []
    @rendered_lines = 0
    buffer = initial ? initial.dup : +''
    cursor = buffer.length
    selection = nil
    hist = nil
    draft = nil
    mention = nil
    slash = nil

    # Hard boundary: drop ref-count debt, restore the pristine console mode and
    # drain stale events from the previous turn. This is the bullet-proofing
    # that prevents the "modifiers dead after the first prompt" class of bug --
    # the next prompt never inherits a polluted console state.
    if WINDOWS && HAVE_WIN_CONSOLE && $stdin.tty?
      ÆtherWinConsole.reset!
      ÆtherWinConsole.flush_input!
    end

    use_win = win_console_available?
    backend = nil
    if use_win
      backend = MouseBackend.build(win: true, mouse: @mouse, chamber: self)
      begin
        backend.begin_capture
      rescue StandardError
        # A spawned tool child can leave the console input handle momentarily
        # disturbed. The Windows backend retries once internally before raising;
        # surrendering here means falling back to TTY::Reader (Ctrl+Backspace and
        # the other ctrl combos are lost on that path).
        backend.disable!
        use_win = false
      end
    end
    return read_prompt_plain(initial) if !use_win && !HAVE_TTY_READER

    @mouse_backend = use_win ? backend : MouseBackend.build(win: false, mouse: @mouse, chamber: self)
    @editor_win = use_win
    bracketed = false
    @anchor_row = nil
    @click_regions = []
    @text_sel = nil
    @drag_anchor = nil
    if use_win
      @anchor_row = anchor_cursor_row
    else
      enable_bracketed_paste
      bracketed = true
      # Anchor before mouse tracking is on so a stray motion event cannot
      # interleave with the DSR response read.
      @anchor_row = anchor_cursor_row
      @mouse_backend.begin_capture if @mouse
    end
    begin
      loop do
        redraw_inline(buffer, cursor, selection, mention, slash)
        input = next_editor_input
        return nil if input.nil?

        if input[:kind] == :mouse
          case input[:action]
          when :motion
            # Drag-extend an in-progress text selection; a bare hover is a no-op
            # (no repaint) so a mouse drifting over the window never flickers.
            if input[:button] == :left && @drag_anchor
              offset = prompt_click_offset(input, buffer)
              if offset
                cursor = offset
                @text_sel = normalize_range(@drag_anchor, offset)
              end
            end
            next
          when :release
            @drag_anchor = nil
            next
          when :click
            if input[:button] == :left
              offset = prompt_click_offset(input, buffer)
              if offset
                # Left click on prompt text: place the cursor and open a drag.
                cursor = offset
                @drag_anchor = offset
                @text_sel = [offset, offset]
                mention = nil if mention
                slash = nil if slash
                next
              end
            end
            # Not prompt text (focus/expand/activate/border): resolve the UI region.
            mention = nil if mention
            slash = nil if slash
            result = apply_mouse_input(input, buffer, cursor, selection)
            if result[0] == :activate
              clear_inline_preview
              print "\n"
              return result[1]
            end
            selection, cursor = result
            next
          else
            # :scroll_up / :scroll_down cycle the Fokus-Ring.
            mention = nil if mention
            slash = nil if slash
            selection, cursor = apply_mouse_input(input, buffer, cursor, selection)
            next
          end
        end

        # Any non-mouse input clears an active text selection; Ctrl+C with an
        # active selection copies it first instead of cancelling the prompt. A
        # modifying input (typing, paste, delete) first consumes the selection so
        # it is replaced, matching standard editor semantics.
        if input[:kind] == :key && input[:action] == :ctrl_c && text_selection_active?
          copy_text_selection(buffer)
          @text_sel = nil
          next
        end
        if modifying_input?(input)
          buffer, cursor, consumed = consume_text_selection(buffer, cursor)
          next if consumed && delete_input?(input)
        else
          @text_sel = nil
        end
       
        if mention
          mention, buffer, cursor = mention_step(mention, input, buffer, cursor)
          next
        end

        if slash
          slash, buffer, cursor = slash_step(slash, input, buffer, cursor)
          next
        end

        case input[:kind]
        when :paste
          selection = nil
          @paste_register << input[:text]
          tag = paste_tag(@paste_register.size, input[:text])
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

          if text == '/'
            buffer.insert(cursor, '/')
            cursor += 1
            slash = { start: 0, index: 0, query: '' } if slash_candidate?(buffer, cursor)
            next
          end

          buffer.insert(cursor, text)
          cursor += text.length
        when :key
          case input[:action]
          when :tab, :back_tab
            selection = next_tab(selection, input[:action] == :tab ? 1 : -1)
          when :newline
            selection = nil
            buffer.insert(cursor, "\n")
            cursor += 1
          when :enter, :return
            if selection
              clear_inline_preview
              print "\n"
            else
              commit_prompt
            end
            return finish_prompt(buffer, selection)
          when :escape
            selection = nil
          when :ctrl_c
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

            if ch == '/'
              buffer.insert(cursor, '/')
              cursor += 1
              slash = { start: 0, index: 0, query: '' } if slash_candidate?(buffer, cursor)
              next
            end

            buffer.insert(cursor, ch)
            cursor += ch.length
          when :up, :ctrl_up
            if instrumentum_at?(selection)
              @expanded_focus[selection] = true
            else
              selection = nil
              buffer, hist, draft = recall_history(buffer, hist, -1, draft)
              cursor = buffer.length
            end
          when :down, :ctrl_down
            if instrumentum_at?(selection)
              @expanded_focus[selection] = false
            else
              selection = nil
              buffer, hist, draft = recall_history(buffer, hist, +1, draft)
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
      return read_prompt_plain(initial)
    ensure
      @mouse_backend&.end_capture if bracketed || use_win
      disable_bracketed_paste if bracketed
      @editor_win = nil
      @mouse_backend = nil
      @anchor_row = nil
      @click_regions = []
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

    decode_tty_char(char)
  end

  # Classify one raw TTY::Reader keypress into the unified input shape shared by
  # the prompt editor and the browse-while-working overlay. Mouse (SGR) and
  # bracketed-paste sequences are resolved here: the former needs the raw SGR
  # bytes, the latter folds a paste into one [PASTED_CONTENT_n] tag.
  def decode_tty_char(char)
    char = complete_extended_key(char)
    char = coalesce_utf8(char)
    if char.start_with?("\e[<")
      parsed = parse_sgr_mouse(char)
      return parsed if parsed
    end
    return tty_read_paste if char.start_with?("\e[200~")

    # Shift+Enter (and a raw LF, e.g. a paste that arrived without bracketed
    # paste) inserts a line break; Enter itself (CR) submits. Keeping the two
    # distinct means a multi-line paste can never fire the prompt early.
    return { kind: :key, action: :newline } if char == "\n" || char == "\e[13;2u" || char == "\e[13;2~"

    action = @tty_keymap[char]
    # tty-reader's win_keys lists the Delete key's extended sequence ([224,83])
    # twice; the later :clear entry wins, so the chamber never sees :delete.
    action = :delete if action == :clear && char == [224, 83].pack('U*')
    action = tty_decode_action(char) if action.nil?
    action = :back_tab if action == :shift_tab

    if action.nil?
      # On Windows msvcrt `_getch` reports Backspace as \b and Ctrl+Backspace as
      # \x7f (DEL) — two distinct keys. Keep them distinct so the TTY fallback
      # (used while the native reader is momentarily unavailable) still deletes
      # a whole word on Ctrl+Backspace instead of a single character. On Unix,
      # DEL *is* backspace, so the legacy mapping is preserved there.
      if char == "\b"
        action = :backspace
      elsif char == "\x7f"
        action = WINDOWS ? :word_backspace : :backspace
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
  # tty-reader surfaces those bytes as codepoints (U+00E0 / U+0000), not raw
  # bytes, so the match must compare ordinals — the raw-byte comparison this
  # used to make never fired and the scan code was silently lost.
  def complete_extended_key(char)
    return char unless WINDOWS && HAVE_WIN_CONSOLE

    cp = char && char.length == 1 ? char.ord : nil
    return char unless cp == 0xE0 || cp == 0x00

    second = ÆtherWinConsole.crt_getch
    return char if second.nil?

    char + [second].pack('U')
  end

  # Reassemble a multi-byte UTF-8 character that msvcrt `_getch` delivered one
  # byte per read_keypress — each byte surfaces as its own Latin-1 codepoint
  # (0x80..0xFF). A lead byte starts a sequence; the continuation bytes are
  # consumed here so the prompt editor receives one correct character instead
  # of a mojibake run like "Ã¤". 0xE0 is skipped: it doubles as the Windows
  # extended-key prefix, so its follower is a scan code, not a UTF-8 byte.
  def coalesce_utf8(ch)
    return ch if ch.nil? || ch.length != 1

    lead = ch.ord
    return ch if lead < 0x80

    nbytes =
      if lead >= 0xF0 then 4
      elsif lead >= 0xE0 then 3
      elsif lead >= 0xC2 then 2
      else return ch
      end
    return ch if lead == 0xE0

    bytes = [lead]
    while bytes.size < nbytes
      nxt = @tty_reader.read_keypress
      break if nxt.nil? || nxt.length != 1
      bytes << nxt.ord
    end

    out = bytes.pack('C*').force_encoding(Encoding::UTF_8)
    out.valid_encoding? ? out : ch
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
    when "\u00E0\x0F", "\u0000\x0F" then :back_tab # _getch extended scan code (Shift+Tab)
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
    # Windows extended-key arrow cluster (U+00E0 = the _getch extended prefix,
    # U+0000 = its null variant). complete_extended_key rejoins the prefix with
    # the scan code as codepoints, so match codepoints here — not raw bytes.
    when "\u00E0H", "\u0000H" then :up
    when "\u00E0P", "\u0000P" then :down
    when "\u00E0K", "\u0000K" then :left
    when "\u00E0M", "\u0000M" then :right
    end
  end

  def redraw_inline(buffer, cursor, selection, mention = nil, slash = nil)
    width = terminal_width
    focus_rows = []
    preview_rows = []
    overlay_rows = if mention
                     mention_overlay_rows(mention, width)
                   elsif slash
                     slash_overlay_rows(slash, width)
                   elsif selection
                     el = tab_positions[selection]
                     focus_rows = focus_list_rows(selection, width)
                     preview_rows = instrumentum_preview_rows(el, selection, width) if el[:type] == :instrumentum
                     focus_rows + preview_rows
                   else
                     []
                   end

    if selection
      el = tab_positions[selection]
      label = truncate_visible(tab_label_for(el), [width - display_width(prompt_marker), 1].max)
      prompt_rows = ["\e[1;35m#{label}\e[0m"]
      block_row = overlay_rows.size
      block_col = display_width(label)
    else
      prompt_rows, brow, bcol = render_prompt_geometry(buffer, cursor, width, active_text_selection)
      block_row = overlay_rows.size + brow
      block_col = bcol
    end

    redraw_block(overlay_rows + prompt_rows, block_row, block_col)

    @click_overlay_rows = overlay_rows.size
    @click_regions = (mention || slash) ? [] : build_click_regions(focus_rows, preview_rows, prompt_rows, selection)

    # On Windows the cursor position is a cheap synchronous call, so re-anchor
    # every frame — a growing multi-line block that scrolls the buffer keeps the
    # click map accurate. Unix anchors once at prompt start instead.
    if @editor_win && (pos = ÆtherWinConsole.cursor_position)
      @anchor_row = pos[1] - block_row
    end

    $stdout.flush
  end

  # Frame geometry for the prompt editor: the accent border (│…│) plus its two
  # padding spaces narrow the wrapable field. Returns
  # [marker_width, inner_width, field_width, content_width].
  def prompt_frame_geometry(width)
    mw = display_width(prompt_marker)
    inner = [width - 2, 2].max
    field = [inner - 2, 1].max
    [mw, inner, field, [field - mw, 1].max]
  end

  # Render the prompt buffer -- which may now contain literal newlines -- into
  # the physical rows to draw plus the cursor's (row, col) inside that block.
  # The block is wrapped in an accent border (no background fill), matching the
  # history prompt banner. The prompt marker occupies the left edge of the first
  # content row; every following row is indented by the same width so wrapped
  # text stays aligned.
  def render_prompt_geometry(buffer, cursor, width, sel = nil)
    mw, inner, field, content_width = prompt_frame_geometry(width)
    rows = []
    cursor_row = nil
    cursor_col = nil
    raw_offset = 0
 
    buffer.split("\n", -1).each_with_index do |raw_line, li|
      line_start = raw_offset
      line_end = raw_offset + raw_line.length
      loc = (cursor >= line_start && cursor <= line_end) ? cursor - line_start : nil
 
      line_sel = nil
      if sel
        ls = sel[0] > line_start ? sel[0] : line_start
        le = sel[1] < line_end ? sel[1] : line_end
        line_sel = [ls - line_start, le - line_start] if le > ls
      end
 
      sub_rows, sub_row, sub_col = wrap_tokens(tokenize_inline(raw_line), loc, content_width, line_sel)
      sub_rows.each_with_index do |text, ri|
        prefix = (li.zero? && ri.zero?) ? prompt_marker : (' ' * mw)
        body = AthanorUI.pad(prefix + text, field)
        rows << @palette.accent(AthanorUI::V) + ' ' + body + ' ' + @palette.accent(AthanorUI::V)
      end

      if sub_row
        cursor_row = rows.size - sub_rows.size + sub_row
        cursor_col = 2 + mw + sub_col
      end

      raw_offset = line_end + 1
    end

    rows.unshift @palette.accent(AthanorUI::TL + (AthanorUI::H * inner) + AthanorUI::TR)
    rows << @palette.accent(AthanorUI::BL + (AthanorUI::H * inner) + AthanorUI::BR)

    [rows, (cursor_row || 0) + 1, cursor_col || (2 + mw)]
  end

  # Split one logical prompt line into styled tokens. Each token is
  # { raw:, prefix:, plain:, style: } -- `raw` is the exact source span,
  # `prefix` the raw length of its opening marker (chars consumed before the
  # visible `plain` text), and `style` a STYLE_CODES key (nil = plain text).
  # Literal runs are single characters so raw offsets map 1:1 to columns.
  def tokenize_inline(raw)
    tokens = []
    i = 0
    n = raw.length
    while i < n
      matched = nil
      INLINE_PATTERNS.each do |pat|
        m = raw.match(pat[:re], i)
        next unless m && m.begin(0) == i

        matched = { raw: m[0], prefix: pat[:prefix], plain: m[pat[:group]], style: pat[:style] }
        break
      end

      if matched
        tokens << matched
        i += matched[:raw].length
      else
        tokens << { raw: raw[i], prefix: 0, plain: raw[i], style: nil }
        i += 1
      end
    end
    tokens
  end

  def render_token(token)
    code = STYLE_CODES[token[:style]]
    code ? "#{code}#{token[:plain]}\e[0m" : token[:plain]
  end
 
  # render_token with a selection span. `raw_start` is the token's raw offset
  # within its logical line; `sel` is a line-relative [start, end] raw range (or
  # nil). The visible plain text occupies [raw_start + prefix, … + plain.length],
  # so the selected slice is wrapped in reverse-video (\e[7m…\e[27m) without
  # disturbing the token's base style or the wrap geometry.
  def render_token_sel(token, raw_start, sel)
    return render_token(token) unless sel
 
    vis_start = raw_start + token[:prefix]
    vis_end = vis_start + token[:plain].length
    s = sel[0] > vis_start ? sel[0] : vis_start
    e = sel[1] < vis_end ? sel[1] : vis_end
    return render_token(token) if e <= s
 
    a = s - vis_start
    b = e - vis_start
    plain = token[:plain]
    out = +''
    code = STYLE_CODES[token[:style]]
    out << code if code
    out << plain[0...a]
    out << "\e[7m" << plain[a...b] << "\e[27m"
    out << plain[b..]
    out << "\e[0m"
    out
  end

  # Wrap a logical line's tokens into physical rows (each at most `width`
  # display columns) and locate the cursor. `cursor_offset` is the cursor's raw
  # offset within the logical line, or nil when the cursor is elsewhere.
  def wrap_tokens(tokens, cursor_offset, width, sel = nil)
    lines = []
    current = +''
    col = 0
    crow = nil
    ccol = nil
    tcol = nil
    raw_pos = 0

    tokens.each do |t|
      raw_start = raw_pos
      raw_end = raw_pos + t[:raw].length
      styled = render_token_sel(t, raw_start, sel)
      pw = display_width(t[:plain])

      if cursor_offset && cursor_offset >= raw_start && cursor_offset < raw_end
        local = cursor_offset - raw_start
        tcol = if local <= t[:prefix]
                 0
               elsif local <= t[:prefix] + t[:plain].length
                 display_width(t[:plain][0...(local - t[:prefix])])
               else
                 pw
               end
        crow = lines.size
        ccol = col + tcol
      end

      if col + pw > width && col.positive?
        lines << current
        current = +''
        col = 0
        if tcol
          crow = lines.size
          ccol = tcol
        end
      end

      current << styled
      col += pw
      raw_pos = raw_end
      tcol = nil
    end

    lines << current
    if cursor_offset && crow.nil?
      crow = lines.size - 1
      ccol = col
    end
    [lines, crow, ccol]
  end

  # Replace exactly the previous prompt block with `rows`, then place the
  # cursor at (cursor_row, cursor_col). Only the block's own lines are touched:
  # `\r\e[K` rewrites one line at a time instead of `\e[J` erasing to the
  # bottom of the screen, so nothing below the prompt is ever repainted.
  def redraw_block(rows, cursor_row, cursor_col)
    prev = @rendered_lines.to_i
    cur = rows.size

    up = @cursor_row.to_i
    print "\e[#{up}A" if up.positive?
    print "\r"

    rows.each do |line|
      print "\e[K"
      print line
      print "\n"
    end

    extra = [prev - cur, 0].max
    extra.times { print "\e[K\n" }

    up_to_cursor = cur + extra - cursor_row
    print "\e[#{up_to_cursor}A" if up_to_cursor.positive?
    print "\r"
    print "\e[#{cursor_col}C" if cursor_col.positive?

    @cursor_row = cursor_row
    @rendered_lines = cur
  end

  # --------------------------------------------------------------- mouse --
  # Terminal mouse tracking. The prompt editor resolves clicks against the
  # screen regions it just drew, so the practitioner may click a focusable to
  # select it, click an instrumentum to expand it, click the prompt to move the
  # cursor, or scroll to cycle the Fokus-Ring. Windows drives this natively
  # (ENABLE_MOUSE_INPUT + MOUSE_EVENT records); Unix uses xterm SGR mode.
 
  # The mouse/selection seam below is driven from MouseBackend (a separate
  # object), so it must be public — the `private` wall earlier in the class
  # would otherwise turn these into NoMethodError from the backend.
  public
 
  def enable_mouse
    print "\e[?1000h\e[?1006h\e[?1002h"
    $stdout.flush
  end

  def disable_mouse
    print "\e[?1002l\e[?1006l\e[?1000l"
    $stdout.flush
  end

  # Absolute screen row (0-based) of the top of the prompt block. Windows reads
  # it straight from the console buffer; Unix asks the terminal where its cursor
  # sits (DSR \e[6n) while the cursor is still on the block's first line.
  def anchor_cursor_row
    return @mouse_backend.anchor_row if @mouse_backend

    if @editor_win
      pos = ÆtherWinConsole.cursor_position
      pos && pos[1]
    else
      pos = query_cursor_position
      pos && pos[0] - 1
    end
  end

  def query_cursor_position
    require 'io/console'
    return nil unless $stdin.tty?

    print "\e[6n"
    $stdout.flush
    resp = +''
    $stdin.raw do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.25
      loop do
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        next unless IO.select([$stdin], nil, nil, 0.1)
        ch = $stdin.read(1)
        break if ch.nil?
        resp << ch
        break if ch == 'R'
      end
    end
    m = resp.match(/\e\[(\d+);(\d+)R/)
    m ? [m[1].to_i, m[2].to_i] : nil
  rescue StandardError
    nil
  end

  # Decode an xterm SGR mouse sequence (e.g. "\e[<0;12;34M") into the unified
  # { kind: :mouse, ... } shape, with x/y normalised to 0-based cells.
  def parse_sgr_mouse(char)
    m = char.match(/\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/)
    return nil unless m

    code = m[1].to_i
    x = m[2].to_i - 1
    y = m[3].to_i - 1

    case
    when code == 64 then { kind: :mouse, action: :scroll_up, button: nil, x: x, y: y }
    when code == 65 then { kind: :mouse, action: :scroll_down, button: nil, x: x, y: y }
    when (code & 32) != 0 then { kind: :mouse, action: :motion, button: sgr_button(code), x: x, y: y }
    when m[4] == 'm' then { kind: :mouse, action: :release, button: nil, x: x, y: y }
    else { kind: :mouse, action: :click, button: sgr_button(code), x: x, y: y }
    end
  end

  def sgr_button(code)
    case code & 0x3
    when 0 then :left
    when 1 then :middle
    when 2 then :right
    end
  end

  # Map each rendered block line to what it is: a focus-list row, an
  # instrumentum preview row, or a prompt-text row. The block-local row equals
  # the region's index in the returned array.
  def build_click_regions(focus_rows, preview_rows, prompt_rows, selection)
    regions = []
    start, = focus_window(selection)
    focus_rows.each_with_index do |_, i|
      regions << { type: :focus, index: (i.zero? || start.nil?) ? nil : start + i - 1 }
    end
    preview_rows.each { regions << { type: :instrumentum, index: selection } }
    prompt_rows.each do
      regions << (selection ? { type: :activate, index: selection } : { type: :prompt, index: nil })
    end
    regions
  end

  # Fold a unified mouse input into a new [selection, cursor] pair (unchanged
  # where the input is irrelevant). Side effects (expand/collapse) happen here.
  def apply_mouse_input(input, buffer, cursor, selection)
    case input[:action]
    when :scroll_up then [next_tab(selection, 1), cursor]
    when :scroll_down then [next_tab(selection, -1), cursor]
    when :click then resolve_mouse_click(input, buffer, cursor, selection) || [selection, cursor]
    else [selection, cursor]
    end
  end

  def resolve_mouse_click(input, buffer, cursor, selection)
    return nil unless @click_regions && !@click_regions.empty? && @anchor_row

    block_row = input[:y] - @anchor_row
    return nil if block_row.negative? || block_row >= @click_regions.size

    region = @click_regions[block_row]
    return nil unless region

    case region[:type]
    when :focus
      return [nil, cursor] if input[:button] == :right
      return [region[:index], cursor] if region[:index]
    when :instrumentum
      if input[:button] == :left && region[:index]
        @expanded_focus[region[:index]] = !@expanded_focus[region[:index]]
      end
    when :activate
      return [:activate, tab_positions[region[:index]]] if input[:button] == :left && region[:index]
    when :prompt
      if input[:button] == :left
        offset = prompt_offset_at(buffer, terminal_width, block_row - @click_overlay_rows, input[:x])
        return [nil, offset] if offset
      end
    end
    nil
  end
   
  # Raw buffer offset for a mouse position that lands on the prompt's editable
  # text (not the border, not a focus/expand/activate region). nil otherwise.
  def prompt_click_offset(input, buffer)
    return nil unless @click_regions && !@click_regions.empty? && @anchor_row
   
    block_row = input[:y] - @anchor_row
    return nil if block_row.negative? || block_row >= @click_regions.size
   
    region = @click_regions[block_row]
    return nil unless region && region[:type] == :prompt
   
    prompt_offset_at(buffer, terminal_width, block_row - @click_overlay_rows, input[:x])
  end
   
  # Normalised [start, end] of the active text selection, or nil when there is
  # none (a collapsed selection counts as none).
  def active_text_selection
    sel = @text_sel
    return nil unless sel && sel[0] != sel[1]
   
    sel[0] < sel[1] ? sel : [sel[1], sel[0]]
  end
   
  def normalize_range(a, b)
    a < b ? [a, b] : [b, a]
  end
   
  def text_selection_active?
    !active_text_selection.nil?
  end
   
  def copy_text_selection(buffer)
    sel = active_text_selection
    return false unless sel
 
    copy_to_clipboard(buffer[sel[0]...sel[1]])
  end
 
  # Collapse an active text selection into a deletion before a modifying edit:
  # returns [buffer, cursor, consumed] with the selected span removed and the
  # cursor at its start. `consumed` is true only when a selection was actually
  # deleted (so delete keys can stop instead of deleting a second character).
  def consume_text_selection(buffer, cursor)
    sel = active_text_selection
    return [buffer, cursor, false] unless sel
 
    buffer.slice!(sel[0]...sel[1])
    @text_sel = nil
    @drag_anchor = nil
    [buffer, sel[0], true]
  end
 
  # True when `input` changes the buffer content (and should therefore replace an
  # active text selection). Navigation/focus/submit keys only clear the selection.
  def modifying_input?(input)
    return true if input[:kind] == :paste || input[:kind] == :literal
    return false unless input[:kind] == :key
 
    case input[:action]
    when :newline, :backspace, :delete, :word_backspace, :ctrl_w, :word_delete, :ctrl_k, :ctrl_u, :literal
      true
    else
      false
    end
  end
 
  # True when `input` deletes text (as opposed to inserting). After such an input
  # consumes a selection, the deletion is already done — no further edit is needed.
  def delete_input?(input)
    input[:kind] == :key &&
      %i[backspace delete word_backspace ctrl_w word_delete ctrl_k ctrl_u].include?(input[:action])
  end
   
  def copy_to_clipboard(text)
    return false if text.nil? || text.empty?
    return @mouse_backend.clipboard_copy(text) if @mouse_backend

    if WINDOWS && HAVE_WIN_CONSOLE
      ÆtherWinConsole.clipboard_copy(text)
    else
      copy_to_clipboard_unix(text)
    end
  end
   
  def copy_to_clipboard_unix(text)
    cmd =
      if system('which pbcopy >/dev/null 2>&1') then 'pbcopy'
      elsif system('which wl-copy >/dev/null 2>&1') then 'wl-copy'
      elsif system('which xclip >/dev/null 2>&1') then 'xclip -selection clipboard'
      elsif system('which xsel >/dev/null 2>&1') then 'xsel --clipboard --input'
      end
    return false unless cmd
   
    IO.popen(cmd, 'w') { |io| io.write(text) }
    true
  rescue StandardError
    false
  end

  # Inverse of render_prompt_geometry: given a prompt-relative row and screen
  # column, return the raw buffer offset the cursor should move to.
  def prompt_offset_at(buffer, width, row, col)
    mw, _inner, _field, content_width = prompt_frame_geometry(width)
    row -= 1 # strip the top border line
    return nil if row.negative?

    content_col = col - 2 - mw # strip left border │ + padding space + marker
    content_col = 0 if content_col.negative?

    global_row = 0
    raw_offset = 0

    buffer.split("\n", -1).each do |raw_line|
      line_start = raw_offset
      tokens = tokenize_inline(raw_line)

      sub_rows = []
      cur = { raw_end: line_start, tokens: [] }
      col_pos = 0
      tok_raw = 0
      tokens.each do |t|
        pw = display_width(t[:plain])
        if col_pos + pw > content_width && col_pos.positive?
          sub_rows << cur
          cur = { raw_end: line_start + tok_raw + t[:prefix], tokens: [] }
          col_pos = 0
        end
        cur[:tokens] << [t, tok_raw, col_pos]
        cur[:raw_end] = line_start + tok_raw + t[:raw].length
        col_pos += pw
        tok_raw += t[:raw].length
      end
      sub_rows << cur

      if (global_row...global_row + sub_rows.size).cover?(row)
        sr = sub_rows[row - global_row]
        sr[:tokens].each do |t, tok_raw, tok_col|
          pw = display_width(t[:plain])
          next unless content_col < tok_col + pw
          local = content_col - tok_col
          return line_start + tok_raw + t[:prefix] + plain_index_at(t[:plain], [local, 0].max)
        end
        return sr[:raw_end]
      end

      global_row += sub_rows.size
      raw_offset = line_start + raw_line.length + 1
      break if global_row > row
    end

    nil
  end

  def plain_index_at(plain, col)
    idx = 0
    seen = 0
    plain.each_char do |ch|
      return idx if seen >= col
      seen += char_width(ch)
      idx += 1
    end
    idx
  end

  # Move the cursor to the fresh line just below the prompt block and leave it
  # clean, so the answer stream starts there. The entered text stays on screen.
  def commit_prompt
    down = @rendered_lines.to_i - @cursor_row.to_i
    print "\e[#{down}B" if down.positive?
    print "\r\e[K"
    @rendered_lines = 0
    @cursor_row = 0
  end

  def enable_bracketed_paste
    print "\e[?2004h"
    $stdout.flush
  end

  def disable_bracketed_paste
    print "\e[?2004l"
    $stdout.flush
  end

  def clear_inline_preview
    up = @cursor_row.to_i
    print "\e[#{up}A" if up.positive?
    print "\r"
    @rendered_lines.to_i.times { print "\e[K\n" }
    print "\e[#{@rendered_lines.to_i}A" if @rendered_lines.to_i.positive?
    @rendered_lines = 0
    @cursor_row = 0
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

  # Step through the line history. Multi-line entries are recalled verbatim --
  # the prompt editor now supports literal newlines, so no re-folding is needed.
  def recall_history(buffer, hist, delta, draft = nil)
    history_step(buffer, hist, delta, draft)
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

  # ------------------------------------------------- slash-command picker --
  # Mirrors the @-mention picker but completes the slash command at the very
  # start of the prompt. Enter mints the highlighted command (the cursor lands
  # ready for its argument), Esc cancels, and typing a space closes the picker
  # so the command's argument can be typed freely.

  def slash_sources
    SLASH_HELP.map do |cmd, desc|
      { command: cmd, desc: desc, chip: cmd,
        label: "#{cmd}  #{desc}", filter: "#{cmd} #{desc}" }
    end
  end

  def slash_filter(query)
    q = query.to_s.downcase.strip
    return slash_sources if q.empty?

    slash_sources.select { |s| s[:filter].to_s.downcase.include?(q) }
  end

  def slash_overlay_rows(slash, width)
    results = slash_filter(slash[:query])
    total = results.size
    idx = total.zero? ? 0 : [[slash[:index], total - 1].min, 0].max
    half = FOCUS_LIST_WINDOW / 2
    start = [idx - half, 0].max
    stop  = [start + FOCUS_LIST_WINDOW, total].min
    start = [stop - FOCUS_LIST_WINDOW, 0].max
    head = total.zero? ? "\e[2m  - kein Befehl passt -\e[0m" : "\e[2m  - Befehle #{idx + 1}/#{total} -\e[0m"
    rows = [head]
    results[start...stop].each_with_index do |el, i|
      at = start + i
      marker = at == idx ? '>' : ' '
      label = "#{el[:command]}  \e[2m#{el[:desc]}\e[0m"
      rows << "  #{marker} #{truncate_visible(label, width - 6)}"
    end
    rows << "\e[2m  - Enter übernimmt, Tab blättert, Esc verwirft, Leertaste = Argument -\e[0m"
    rows
  end

  def slash_step(slash, input, buffer, cursor)
    slash[:query] = buffer[(slash[:start] + 1)..cursor].to_s
    results = slash_filter(slash[:query])

    case input[:kind]
    when :key
      case input[:action]
      when :enter, :return
        return finish_slash(slash, results[slash[:index]], buffer, cursor)
      when :escape
        return [nil, buffer, cursor]
      when :ctrl_c
        buffer.slice!(slash[:start]..)
        return [nil, buffer, slash[:start]]
      when :up, :back_tab
        slash[:index] = results.empty? ? 0 : (slash[:index] - 1) % results.size
      when :down, :tab
        slash[:index] = results.empty? ? 0 : (slash[:index] + 1) % results.size
      when :backspace
        if cursor > slash[:start] + 1
          buffer.slice!(cursor - 1)
          cursor -= 1
        else
          return [nil, buffer, cursor]
        end
      when :literal
        ch = input[:char]
        buffer.insert(cursor, ch)
        cursor += ch.length
        return [nil, buffer, cursor] if ch.match?(/\s/)
        slash[:index] = 0
      end
    when :literal
      text = input[:text].to_s
      buffer.insert(cursor, text)
      cursor += text.length
      return [nil, buffer, cursor] if text.match?(/\s/)
      slash[:index] = 0
    when :paste
      text = input[:text].to_s
      buffer.insert(cursor, text)
      cursor += text.length
      return [nil, buffer, cursor] if text.match?(/\s/)
      slash[:index] = 0
    end
    [slash, buffer, cursor]
  end

  def finish_slash(slash, el, buffer, cursor)
    return [nil, buffer, cursor] if el.nil?

    replacement = el[:chip].to_s
    buffer.slice!(slash[:start]...cursor)
    buffer.insert(slash[:start], replacement)
    [nil, buffer, slash[:start] + replacement.length]
  end

  # True when the `/` just typed sits at the very start of the prompt and the
  # text up to the cursor is still a bare command token (`/` + non-space run).
  def slash_candidate?(buffer, cursor)
    buffer[0...cursor].match?(/\A\/[^\s]*\z/)
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

  def history_step(buffer, hist, delta, draft = nil)
    items = @line_history
    return [buffer, hist, draft] if items.empty?

    if hist.nil?
      return [buffer, hist, draft] unless delta.negative?

      # First upward navigation: save the in-progress text so it can be
      # restored when the user steps back down past the newest entry.
      draft = buffer.dup
      idx = items.size - 1
    else
      idx = hist + delta
    end

    # Stepped past the newest entry -- bring back the draft (empty if none).
    return [(draft || +'').dup, nil, draft] if idx >= items.size
    return [items[0].dup, 0, draft] if idx.negative?

    [items[idx].dup, idx, draft]
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

    m = buffer[0...cursor].match(/\[PASTED_CONTENT_\d+(?: · \d+ Zeichen)?\]\z/)
    m && [cursor - m[0].length, m[0].length]
  end

  def tag_after(buffer, cursor)
    m = buffer[cursor..].to_s.match(/\A\[PASTED_CONTENT_\d+(?: · \d+ Zeichen)?\]/)
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

  SLASH_HELP = [
    ['/help',       'Zeige diese Hilfe'],
    ['/aegis',      'Aegis-Orientierung zeigen'],
    ['/morph',      'Begleiter-Checkboxen (an/ab, Leertaste + Enter)'],
    ['/unmorph',    'Begleiter entfernen'],
    ['/personae',   'Alle zwölf Begleiter auflisten'],
    ['/file',       'Datei an die nächste Frage heften'],
    ['/continue [bemerkung]', 'Unvollendeten Zug fortsetzen (+ optionale Anmerkung)'],
    ['/edit',              'Letzte Eingabe erneut bearbeiten'],
    ['/history [n|flags]', 'Verlauf zeigen (Sitzung + Chronik)'],
    ['/edit',       'Letzte Eingabe erneut bearbeiten'],
    ['/config',     'Konfiguration zeigen'],
    ['/context',    'Abgeleiteten Kontext zeigen'],
    ['/tools',      'Werkzeug-Browser (Tab = Doku) · /tools <name> = Detail'],
    ['/tool',       'Werkzeug-Doku direkt (Alias)'],
    ['/markdown',   'Markdown-Rendering an/aus'],
    ['/highlight',  'Syntax-Highlighting an/aus'],
    ['/theme',      'Highlight-Theme wählen'],
    ['/cost',       'Token-Kosten zeigen'],
    ['/mouse',      'Maus-Klicksteuerung an/aus (Aus = native Textauswahl)'],
    ['/session-list',      'Hydra-Sitzungen anzeigen (aktiv/stale/closed)'],
    ['/resume-session <id|pid|#>', 'Sitzung fortsetzen (Zustand + Verlauf laden)'],
    ['/exit',       'Die Kammer verlassen']
  ].freeze

  def slash_commands
    %w[/help /aegis /morph /unmorph /personae /file /clear /history /config /context /tools
       /tool /markdown /highlight /theme /cost /mouse /session-list /resume-session /session-resume /continue /edit /exit]
  end

  # ---------------------------------------------------------------- slash --

  def handle_slash(input)
    cmd, _, arg = input.partition(/\s+/)
    arg = arg.strip

    case cmd
    when '/help'                    then show_help
    when '/aegis'                   then aegis_summary
    when '/morph', '/veil'          then morph(arg)
    when '/unmorph', '/release'     then unmorph(arg)
    when '/personae', '/companions' then list_personae
    when '/file'                    then attach_file(arg)
    when '/clear'                   then clear_history
    when '/continue'                then continue_turn(arg)
    when '/edit', '/re'             then edit_last_prompt
    when '/history'                 then show_history(arg)
    when '/config'                  then config_summary
    when '/context'                 then context_summary
    when '/tools'                   then list_tools(arg)
    when '/tool'                    then list_tools(arg)
    when '/markdown'                then toggle_markdown
    when '/highlight'               then toggle_highlight
    when '/mouse'                   then toggle_mouse
    when '/theme'                   then set_theme(arg)
    when '/cost'                    then cost_summary
    when '/session-list', '/sessions'      then session_list_cmd
    when '/resume-session', '/session-resume', '/resume' then resume_session_cmd(arg)
    when '/exit', '/quit' then @quit = true
    else
      puts "Unbekannter Befehl: #{cmd}"
    end
  end

  def show_help
    width = [terminal_width, 96].min
    cmds = [
      ['/morph',             'Checkboxen-Panel: Begleiter an-/abwählen'],
      ['/morph <begleiter>', 'Einzelnen Begleiter hinzufügen'],
      ['/unmorph [b]',       'Begleiter entfernen (ohne Argument: alle)'],
      ['/personae',          'Alle zwölf Begleiter auflisten'],
      ['/file <pfad>',       'Datei an die nächste Frage heften'],
      ['@begleiter',         'Stimme für genau eine Runde beschwören'],
      ['@file:<pfad>',       'Datei an die nächste Frage heften'],
      ['@',                  'Sigillen-Picker öffnen'],
      ['/',                  'Befehls-Picker öffnen'],
      ['Tab / Shift-Tab',    'Fokus-Positionen durchlaufen'],
      ['/clear',             'Gesprächsverlauf löschen'],
      ['/continue [bemerkung]', 'Unvollendeten Zug fortsetzen (+ optionale Anmerkung)'],
      ['/history [n|flags]', 'Verlauf zeigen (Sitzung + Chronik)'],
      ['/config',            'Konfiguration zeigen'],
      ['/context',           'Abgeleiteten Kontext zeigen'],
      ['/aegis',             'Aegis-Orientierung zeigen (Tags, Summary, Notizen)'],
      ['/tools',             'Verfügbare Werkzeuge listen'],
      ['/markdown',          'Markdown-Rendering an/aus'],
      ['/highlight',         'Syntax-Highlighting an/aus'],
      ['/mouse',             'Maus-Klicksteuerung an/aus'],
      ['/theme <name>',      'Highlight-Theme wählen'],
      ['/cost',              'Token-Kosten der Sitzung zeigen'],
      ['/session-list',      'Hydra-Sitzungen anzeigen (aktiv/stale/closed)'],
      ['/resume',            'Sitzungs-Auswahl: unfertige Züge durchsehen + fortsetzen'],
      ['/resume-session <id|pid|#>', 'Sitzung direkt fortsetzen (Zustand + Verlauf laden)'],
      ['$',                  'π → ÆtherShell: Nushell-artige Daten-Pipelines (exit zurück)'],
      ['/exit, exit',        'Die Kammer verlassen']
    ]
    puts
    puts AthanorUI.box('Dialog-Kammer · Befehle', [], width: width, palette: @palette)
    puts AthanorUI.table(['Befehl', 'Wirkung'], cmds, width: width, palette: @palette)
    puts @palette.dim('  Begleiter: owl kitsune phoenix ouroboros bastet fenrir undine schwan drache corax jindujun solomon')
  end

  def list_personae
    rows = COMPANION_PERSONALITIES.map do |glyph, p|
      temper = CompanionPrograms.temperament(glyph)
      [@veiled.include?(glyph) ? '*' : '', p[:glyph].to_s, p[:name].to_s, glyph.to_s,
       "T:#{temper[:temperature]}", "D:#{temper[:thinking]}"]
    end
    puts AthanorUI.table(['', 'Glyph', 'Begleiter', 'Key', 'Temp', 'Denken'], rows,
                       width: [terminal_width, 96].min, palette: @palette)
    puts @palette.dim('  * = aktuell entschleiert')
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
    @pending_turn = nil
    Readline::HISTORY.clear if HAVE_READLINE
    puts 'Gesprächsverlauf gelöscht.'
  end

  # `/edit` -- load the last submitted prompt back into the editor so it can be
  # revised and re-submitted (the counterpart to `/continue`, which re-runs it
  # verbatim). Prefers the in-flight/aborted prompt, then the line history.
  def edit_last_prompt
    last = last_prompt_text
    if last.nil? || last.empty?
      puts @palette.dim('  Keine letzte Eingabe zum Bearbeiten.')
      return
    end
    @prefill = last
    puts @palette.dim('  Letzte Eingabe in den Editor geladen -- bearbeiten und Enter.')
  end

  def last_prompt_text
    pending = @pending_turn && @pending_turn[:prompt].to_s.strip
    return pending unless pending.empty?

    @line_history.reverse_each do |ln|
      stripped = ln.to_s.strip
      return stripped unless stripped.empty?
    end
    nil
  end

  def show_history(arg)
    session_only = false
    chronicle_only = false
    global = false
    limit = 7
    arg.to_s.split.each do |a|
      case a
      when '--session', '-s'   then session_only = true
      when '--chronicle', '-c' then chronicle_only = true
      when '--global', '-g', '--all' then global = true
      when /\A\d+\z/           then limit = a.to_i
      end
    end

    render_session_history unless chronicle_only
    render_chronicle(limit, global: global)  unless session_only
  end

  # A prominent, bordered + background-filled block for the practitioner's
  # prompt in the history views (multi-line prompts wrap to the terminal).
  def render_prompt_banner(prompt)
    text = prompt.to_s.strip
    text = '(leer)' if text.empty?
    width = [terminal_width - 2, 4].max
    AthanorUI.prompt_box('π ', text, width: width, palette: @palette).each { |row| puts row }
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
      render_prompt_banner(h[:prompt])
      ans = h[:answer].to_s.strip
      puts ans.empty? ? '   (keine Antwort)' : ans
      puts
    end
  end

  def render_chronicle(limit, global: false)
    unless defined?(Mnemosyne)
      begin
        require_relative '../mnemosyne/mnemosyne'
      rescue LoadError, StandardError
        puts 'Chronik nicht verfügbar.'
        return
      end
    end
    # Scoped to the live head by default so /history reflects the session being
    # continued; --global/-g reveals the cross-session chronicle instead. When no
    # session is bound, current_session_id is nil and the query stays global.
    sid = global ? nil : Mnemosyne.current_session_id
    scope = global ? 'global' : 'session'
    entries = Mnemosyne.fetch_history(limit: limit, session_id: sid)
    if entries.nil? || entries.empty?
      puts "\e[1mChronik (persistent, #{scope})\e[0m -- keine Einträge"
      return
    end
    puts "\e[1mChronik (persistent, #{scope})\e[0m -- letzte #{entries.size}"
    entries.each do |e|
      stamp = e[:created_at] || e[:timestamp]
      puts "-- #{stamp}  (#{e[:tool_call_count].to_i} tools)"
      render_prompt_banner(e[:prompt])
      ans = e[:answer].to_s.strip
      puts ans.empty? ? '   (keine Antwort)' : ans
      puts
    end
  end

  def config_summary
    rows = [
      ['Model', CONFIG.model],
      ['API',   CONFIG.api_type],
      ['Flash', CONFIG.fast_model]
    ]
    puts AthanorUI.box('Konfiguration', AthanorUI.kv(rows, palette: @palette),
                     width: [terminal_width, 80].min, palette: @palette)
  end

  def context_summary
    rows = [
      ['Projekt',   CONFIG.project_name],
      ['Root',      CONFIG.project_root],
      ['Memory-DB', CONFIG.memory_db_path]
    ]
    puts AthanorUI.box('Kontext', AthanorUI.kv(rows, palette: @palette),
                     width: [terminal_width, 80].min, palette: @palette)
  end

  # `/aegis` — the oracle's persistent orientation: the living Aegis state
  # (summary, tags, temperament, working directory) plus the notes currently
  # within recall reach. Mirrors `aetheroracle aegis`, but framed for the REPL.
  def aegis_summary
    ensure_mnemosyne
    return unless defined?(Mnemosyne)

    Mnemosyne.restore_aegis if Mnemosyne.respond_to?(:restore_aegis)
    a = Mnemosyne.aegis || {}
    a = {} unless a.respond_to?(:[])

    rows = [
      ['Summary',     a[:summary].to_s.empty? ? '—' : a[:summary].to_s],
      ['Tags',        aegis_tags(a).join(', ')],
      ['Temperature', a[:temperature].to_s],
      ['Thinking',    a[:thinking].to_s.empty? ? '—' : a[:thinking].to_s],
      ['Working Dir', a[:working_dir].to_s.empty? ? '—' : a[:working_dir].to_s]
    ]
    puts AthanorUI.box('Aegis', AthanorUI.kv(rows, palette: @palette),
                       width: [terminal_width, 80].min, palette: @palette)

    notes = Array(Mnemosyne.recall_aegis_notes(limit: 8))
    puts
    if notes.empty?
      puts @palette.dim('  Keine Aegis-Notizen in Reichweite.')
    else
      puts @palette.dim("  #{notes.size} Aegis-Notizen in Reichweite:")
      notes.each_with_index do |n, i|
        content = (n[:content] || n['content']).to_s.gsub(/\s+/, ' ').strip
        score   = (n[:score] || n['score']).to_s
        puts @palette.dim("  #{i + 1}. [#{score}] #{content[0, 160]}")
      end
    end
    puts
  end

  def aegis_tags(a)
    t = a[:tags]
    t = t.split(',') if t.is_a?(String)
    Array(t).map(&:to_s).reject(&:empty?)
  end

  def session_list_cmd
    ensure_mnemosyne
    return unless defined?(Mnemosyne)

    sessions = Mnemosyne.all_sessions(hide_empty: true)
    if sessions.empty?
      puts @palette.dim('  Keine Hydra-Sitzungen.')
      return
    end

    width = [terminal_width, 110].min
    rows = sessions.map { |s| session_line(s) }
    puts AthanorUI.box('Hydra Sessions', rows, width: width, palette: @palette)
    puts
    puts @palette.dim("  #{sessions.size} Sitzungen — '/resume-session <id>' setzt eine stale/closed Sitzung fort (Zustand + Tool-Ergebnisse bleiben erhalten).")
    puts
  end

  def resume_session_cmd(arg)
    ensure_mnemosyne
    return unless defined?(Mnemosyne)

    ref = arg.to_s.strip
    if ref.empty?
      resume_chooser
      return
    end

    target = resolve_session(ref)
    unless target
      puts @palette.fail("  Sitzung nicht gefunden: #{ref} — nutze '/session-list' für ids/pids.")
      return
    end

    sid = target[:session_id]

    # Unload the current session before adopting another: the chamber process
    # switches identity, so the old row is marked closed and future writes flow
    # to the adopted session.
    old_sid = Mnemosyne.current_session_id
    if old_sid && old_sid.to_s != sid.to_s && Mnemosyne.respond_to?(:close_session)
      Mnemosyne.close_session(session_id: old_sid)
    end

    session = Mnemosyne.proceed_session(session_id: sid)
    unless session
      puts @palette.fail("  Sitzung nicht fortsetzbar: #{sid}")
      return
    end

    # Adopt the target as the live head: subsequent records, heartbeats and
    # Aegis writes route to this session via both identity markers.
    Mnemosyne.current_session_id = sid
    Thread.current[:hydra_session_id] = sid

    imported = import_session_history(sid, state: session[:state])
    note = imported.positive? ? "#{imported} Züge in den Kontext geladen" : 'kein Verlauf vorhanden'

    # A session interrupted mid-turn carries a persisted resume_state: restore
    # it so /continue finishes the exact unfinished turn, not just its history.
    if restore_pending_turn(session[:state])
      note += " · unvollendeter Zug wiederhergestellt — /continue setzt fort"
    end

    puts @palette.success("  Fortgesetzt: #{sid} (#{session[:label]}) — Zustand wiederhergestellt, #{note}.")
  end

  # Interactive session chooser: lists every sibling session (except the live
  # head), previews each one's last unfinished turn, and resumes the selection.
  def resume_chooser
    sessions = Mnemosyne.all_sessions(hide_empty: true)
    current = Mnemosyne.current_session_id.to_s

    candidates = sessions.reject { |s| s[:session_id].to_s == current }
    if candidates.empty?
      puts @palette.dim('  Keine anderen Hydra-Sitzungen zum Fortsetzen.')
      return
    end

    labels = candidates.map { |s| session_choice_label(s) }
    choice = fullscreen_select_menu(
      labels,
      allow_custom: false,
      single_key: false,
      title: "Hydra-Sitzungen fortsetzen — #{candidates.size} verfügbar"
    )
    return unless choice

    idx = labels.index(choice)
    return unless idx

    target = candidates[idx]
    return unless target

    resume_session_cmd(target[:session_id].to_s)
  end

  # A plain-text (ANSI-free) label for the interactive chooser: status, name,
  # age, Aegis silhouette and — when the session carries an unfinished turn —
  # a preview of what it was doing when it was interrupted.
  def session_choice_label(s)
    status = s[:effective_status].to_s
    age = s[:age_seconds].to_i
    age_s = age < 60 ? "#{age}s" : "#{age / 60}m#{age % 60}s"
    name = s[:label].to_s.strip
    name = s[:session_id].to_s if name.empty?
    summary = s[:aegis_summary].to_s.strip

    head = "[#{status.ljust(6)}] #{name} · #{age_s} ago"
    head += " · #{summary[0, 40]}" unless summary.empty?

    preview = unfinished_turn_preview(s)
    preview ? "#{head}  ◆ #{preview}" : head
  end

  # Summarise the durable resume_state's last unfinished turn: the partial
  # answer if one exists, else the most recent user prompt, plus the last tool
  # call and how many results had already accumulated. Returns nil when the
  # session has no in-flight state (a cleanly finished turn clears state_json).
  def unfinished_turn_preview(s)
    return nil unless s[:resumable]

    state = Mnemosyne.load_session_state(session_id: s[:session_id])
    return nil unless state.is_a?(Hash)

    messages = state[:messages] || state['messages'] || []
    tool_results = state[:tool_results] || state['tool_results'] || []
    answer = state[:answer] || state['answer']

    last_prompt = nil
    last_tool = nil
    Array(messages).each do |m|
      m = m.transform_keys(&:to_sym) if m.respond_to?(:transform_keys)
      txt = extract_message_text(m[:content])
      last_prompt = txt if m[:role].to_s == 'user' && !txt.empty?
      tc = m[:tool_calls]
      next unless tc.is_a?(Array) && !tc.empty?

      fn = tc.last.is_a?(Hash) ? (tc.last[:function] || tc.last['function']) : nil
      last_tool = fn.is_a?(Hash) ? (fn[:name] || fn['name']).to_s : tc.last.to_s
      last_tool = last_tool.to_s.strip
    end

    parts = []
    if answer && !answer.to_s.strip.empty?
      parts << "Teilantwort: #{collapse_text(answer.to_s, 64)}"
    elsif last_prompt && !last_prompt.empty?
      parts << "Aufgabe: #{collapse_text(last_prompt, 64)}"
    else
      parts << 'Turn unterbrochen'
    end
    parts << "Tool: #{last_tool}" if last_tool && !last_tool.empty?
    parts << "#{Array(tool_results).size} Ergebnisse" if Array(tool_results).size.positive?

    parts.join(' · ')
  rescue StandardError
    nil
  end

  def collapse_text(text, max)
    text.to_s.gsub(/\s+/, ' ').strip[0, max]
  end

  # Resolve a /resume-session argument to a session row: exact session_id first,
  # then pid, then a 1-based index into the /session-list ordering.
  def resolve_session(ref)
    return nil if ref.to_s.strip.empty?

    all = Mnemosyne.all_sessions
    return nil if all.empty?

    exact = all.find { |s| s[:session_id].to_s == ref }
    return exact if exact

    by_pid = all.find { |s| s[:pid].to_s == ref }
    return by_pid if by_pid

    idx = ref.to_i
    return all[idx - 1] if idx >= 1 && idx <= all.size

    nil
  end

  # Adopt a session's conversation: load its Chronicle history into @history so
  # the next prompt genuinely continues that thread (not just re-stamps the row).
  def import_session_history(sid, state: nil)
    entries = Mnemosyne.fetch_history(session_id: sid, limit: 100, include_tool_calls: true)
    unless entries.nil? || entries.empty?
      @history = entries.map do |e|
        { prompt: e[:prompt], answer: e[:answer], tool_calls: e[:tool_calls] || [], created_at: e[:created_at] }
      end
      return @history.size
    end

    # Legacy sessions predate session_id attribution: every chronicle row carries
    # NULL, so the session-scoped query is empty. Fall back to the crash-resume
    # state (state_json.messages) — the full durable transcript — and weave it
    # back into @history so the next prompt genuinely continues that thread.
    messages = state && (state[:messages] || state['messages'])
    return 0 unless messages.is_a?(Array) && !messages.empty?

    @history = messages_to_history(messages)
    @history.size
  end

  # Convert durable crash-resume messages (OpenAI-style role/content) back into
  # the chamber's @history shape ({prompt:, answer:}). System/tool noise is
  # dropped. A function-calling transcript interleaves empty tool-call-only
  # assistant messages and `tool` results, so we key off non-empty text: each
  # answer pairs with the most recent user prompt (or its own text as a fallback).
  def messages_to_history(messages)
    history = []
    pending_prompt = nil
    messages.each do |m|
      m = m.transform_keys(&:to_sym) if m.respond_to?(:transform_keys)
      role = m[:role].to_s
      content = extract_message_text(m[:content])
      case role
      when 'user'
        pending_prompt = content unless content.empty?
      when 'assistant'
        next if content.empty?
        history << { prompt: pending_prompt || content, answer: content, tool_calls: [], created_at: Time.now }
        pending_prompt = nil
      end
    end
    history
  end

  def extract_message_text(content)
    return '' if content.nil?
    return content if content.is_a?(String)
    if content.is_a?(Array)
      return content.map { |p| p.is_a?(Hash) ? (p[:text] || p['text'] || p[:content] || p['content']).to_s : p.to_s }.join("\n")
    end
    content.to_s
  end

  def session_line(s)
    status = s[:effective_status].to_s
    color = case status
            when 'active' then @palette.method(:success)
            when 'stale'  then @palette.method(:warn)
            else @palette.method(:fail)
            end
    age = s[:age_seconds].to_i
    age_s = age < 60 ? "#{age}s" : "#{age / 60}m#{age % 60}s"
    name = s[:label].to_s.strip
    name = s[:session_id].to_s if name.empty?
    flag = s[:resumable] ? ' ◆' : ''
    summary = s[:aegis_summary].to_s.strip
    summary = summary.empty? ? '' : " · #{summary[0, 48]}"
    id = @palette.dim(s[:session_id].to_s)
    "#{color.call("[#{status.ljust(6)}]")} #{name}#{flag}  #{@palette.dim("(#{s[:role]}, pid #{s[:pid]}, #{age_s} ago)")}#{summary}  #{id}"
  end

  # Ensure Mnemosyne is loaded before reading the Aegis state; `/aegis` may run
  # before the first turn has lazily required it (inscribe_chronicle does so).
  def ensure_mnemosyne
    return if defined?(Mnemosyne)

    require_relative '../mnemosyne/mnemosyne'
  rescue LoadError, StandardError
    puts @palette.warn('  Mnemosyne nicht verfügbar — Aegis nicht lesbar.')
  end

  def tool_names
    @tools.tools.keys.map(&:to_s).sort
  end

  # `/tools` lists the instrument names only (compact, description-free); the
  # documentation is revealed on demand — either by naming a tool
  # (`/tools <name>`) or by browsing with Tab/↑↓ in the interactive picker,
  # which renders each tool's documentation as markdown.
  def list_tools(arg = nil)
    names = tool_names
    return puts(@palette.dim('  Keine Werkzeuge registriert.')) if names.empty?

    return show_tool_detail(arg.strip) unless arg.to_s.strip.empty?

    if $stdin.tty? && inline_tab_available?
      browse_tools(names)
    else
      print_tool_list(names)
    end
  end

  def print_tool_list(names)
    width = [terminal_width, 100].min
    puts AthanorUI.box('Werkzeuge', [], width: width, palette: @palette)
    columnize(names, width: width).each { |line| puts line }
    puts
    puts @palette.dim("  #{names.size} Werkzeuge — '/tools <name>' zeigt die Doku, '/tools' öffnet den Browser.")
    puts
  end

  def show_tool_detail(name)
    tool = @tools.tools[name.to_sym] || @tools.tools[name.to_s]
    if tool.nil?
      hit = tool_names.find { |n| n.casecmp?(name) } || tool_names.grep(/#{Regexp.escape(name)}/i).first
      tool = @tools.tools[hit.to_sym] if hit
    end
    unless tool
      puts "Unbekanntes Werkzeug: #{name}"
      puts "Verfügbar: #{tool_names.join(', ')}"
      return
    end
    render_tool_document(tool)
  end

  def render_tool_document(tool)
    width = [terminal_width, 100].min
    md = +"# `#{tool.name}`\n\n"
    md << tool.description.to_s.strip << "\n"
    if tool.params && !tool.params.empty?
      md << "\n## Parameter\n\n"
      md << "| Parameter | Typ | Default |\n|---|---|---|\n"
      tool.params.each do |pname, pspec|
        pspec = {} unless pspec.is_a?(Hash)
        type = (pspec[:type] || pspec['type'] || '—').to_s
        if pspec.key?(:default) || pspec.key?('default')
          default = pspec[:default] || pspec['default']
          default = default.nil? ? '—' : default.to_s
        elsif pspec[:required] || pspec['required']
          default = '*erforderlich*'
        else
          default = '—'
        end
        md << "| `#{pname}` | `#{type}` | #{default} |\n"
      end
    end
    puts
    puts ÆtherTerminalMarkdown.render(md, theme: @highlight ? @theme : nil, width: width)
    puts
  end

  def tool_description_markdown(tool)
    +"### `#{tool.name}`\n\n#{tool.description.to_s.strip}"
  end

  def browse_tools(names)
    idx = 0
    @tool_browser_lines = 0
    use_win = win_console_available?
    if use_win
      begin
        ÆtherWinConsole.begin_raw_input(mouse: false)
      rescue StandardError
        ÆtherWinConsole.disable!
        use_win = false
      end
    end

    begin
      loop do
        draw_tool_browser(names, idx)
        input = use_win ? ÆtherWinConsole.next_input : tty_editor_input
        break if input.nil?
        next unless input.is_a?(Hash)

        case input[:kind]
        when :key
          case input[:action]
          when :up, :back_tab then idx = (idx - 1) % names.size
          when :down, :tab    then idx = (idx + 1) % names.size
          when :enter, :return, :right
            clear_tool_browser
            render_tool_document(@tools.tools[names[idx].to_sym])
            return
          when :escape, :ctrl_c
            clear_tool_browser
            return
          when :literal
            ch = (input[:char] || '').to_s.downcase
            if ch.match?(/\A[[:graph:]]\z/)
              hit = names.index { |n| n.downcase.start_with?(ch) }
              idx = hit if hit
            end
          end
        end
      end
    rescue ÆtherWinConsole::ConsoleInputError
      ÆtherWinConsole.disable!
      use_win = false
      ÆtherWinConsole.end_raw_input
      clear_tool_browser
      print_tool_list(names)
    ensure
      ÆtherWinConsole.end_raw_input if use_win
    end
  end

  def draw_tool_browser(names, idx)
    n = @tool_browser_lines
    STDOUT.print "\e[#{n}A" if n.positive?
    STDOUT.print "\r\e[J"

    width = [terminal_width, 96].min
    tool = @tools.tools[names[idx].to_sym]
    preview = ÆtherTerminalMarkdown.render(tool_description_markdown(tool),
                                           theme: @highlight ? @theme : nil,
                                           width: width).split("\n").first(6)

    half = FOCUS_LIST_WINDOW / 2
    start = [idx - half, 0].max
    stop  = [start + FOCUS_LIST_WINDOW, names.size].min
    start = [stop - FOCUS_LIST_WINDOW, 0].max

    rows = []
    rows << "  #{@palette.accent('Werkzeuge')}  #{@palette.dim("#{names.size} · Tab/↑↓ blättern · Enter Doku · Esc zurück")}"
    names[start...stop].each_with_index do |name, i|
      at = start + i
      marker = at == idx ? @palette.accent('>') : ' '
      rows << "   #{marker} #{at == idx ? @palette.accent(name) : name}"
    end
    rows << "  #{@palette.accent('─' * [width - 4, 1].max)}"
    preview.each { |l| rows << l }
    rows << @palette.dim('  Enter: vollständige Markdown-Dokumentation · Esc: zurück')
    @tool_browser_lines = rows.size
    STDOUT.print rows.join("\n")
    STDOUT.print "\n"
    STDOUT.flush
  end

  def clear_tool_browser
    n = @tool_browser_lines.to_i
    STDOUT.print "\e[#{n}A" if n.positive?
    STDOUT.print "\r\e[J"
    @tool_browser_lines = 0
    STDOUT.flush
  end

  # Wrap a list of names into fixed-width columns (name-only, description-free).
  def columnize(names, width: 80)
    return [] if names.empty?

    max = names.map { |n| display_width(n) }.max
    col_w = max + 2
    cols = [width / col_w, 1].max
    names.each_slice(cols).map { |row| row.map { |n| n.ljust(col_w - 2) }.join('  ').rstrip }
  end

  def toggle_markdown
    @render_markdown = !@render_markdown
    puts "Markdown-Rendering #{@render_markdown ? 'an' : 'aus'}."
  end

  def toggle_highlight
    @highlight = !@highlight
    puts "Syntax-Highlighting #{@highlight ? 'an' : 'aus'}."
  end

  def toggle_mouse
    @mouse = !@mouse
    puts @mouse ? 'Maus-Klicksteuerung AN (native Textauswahl im Editor deaktiviert).' \
                : 'Maus-Klicksteuerung AUS (native Textauswahl aktiv, Klick-Fokus deaktiviert).'
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

  def cost_summary
    s = TokenLedger.session
    p = TokenLedger.persisted
    rows = [
      ['Session',  "#{TokenLedger.format_usd(s[:cost])} · #{s[:prompt_tokens]} prompt + " \
                   "#{s[:completion_tokens]} completion · #{s[:turns]} Turns"],
      ['All-time', "#{TokenLedger.format_usd(p[:cost])} · #{p[:prompt_tokens]} prompt + " \
                   "#{p[:completion_tokens]} completion · #{p[:sessions]} Sessions"],
      ['Model',    "#{CONFIG.model} / flash #{CONFIG.fast_model}"]
    ]
    puts AthanorUI.box('Token-Ledger', AthanorUI.kv(rows, palette: @palette),
                     width: [terminal_width, 80].min, palette: @palette)
  end

  def banner
    glyph = @veiled.empty? ? '*' : active_glyphs_display
    rows = [
      "  #{glyph}  Der Kristall ist gestimmt; zwölf Stimmen harren.",
      '  /morph ruft sie — /unmorph entlässt sie — exit geht.',
      '  $ transmorphiert die π-Prompterei in die ÆtherShell (exit kehrt zurück).'
    ]
    puts AthanorUI.box("Dialog-Kammer · ÆtherCodex v#{oracle_version}", rows, width: [terminal_width, 80].min, palette: @palette)
    puts
  end

  def oracle_version
    defined?(AetherOracle::VERSION) ? AetherOracle::VERSION : 'dev'
  end

  def farewell
    puts "\e[2m  :: Der Schleier schließt sich. Möge der Äther dich tragen.\e[0m"
    puts TokenLedger.closing_line
    TokenLedger.end_session!
  end
end