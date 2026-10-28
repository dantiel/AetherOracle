# frozen_string_literal: true

require 'stringio'
require 'thread'
require_relative 'win_console_input'
require_relative 'oracle'
require_relative 'conduit'
require_relative 'coniunctio'
require_relative '../mnemosyne/mnemosyne'
require_relative '../instrumentarium/instrumenta'

# Hydra — the multi-headed terminal multiplexer for PythiaCLI.
#
# tmux-shaped but native (no tmux required): a grid of virtual "heads", each an
# independent worker with its own prompt input, all breathing one shared
# Mnemosyne context (.aether/mnemosyne.db is busy_timeout-guarded, so notes,
# the Ægis orientation and the chronicle are one context across every worker).
#
# FlashAegis is the master head — the brain at the top that decomposes a prompt
# into sub-tasks and dispatches them to freshly spawned heads (or to heads you
# name with /assign). Every head runs its own Oracle.divination in a background
# thread, so heads work in parallel.
#
#   Ctrl+B  prefix (tmux-style)
#     arrows   switch active head          c   spawn a head
#     x        despawn active head         n/p next / prev
#     [        scroll mode                 ?   help
#     d        quit                        Esc/q cancel prefix
#
# While typing, a head is a REPL: Enter submits, arrows move the cursor,
# Ctrl+W/A/E/K/U edit, PgUp/PgDn scroll the stream, Ctrl+D quits.
class Hydra
  DECOMPOSE_SYSTEM = <<~TEXT.freeze
    You are the Hydra brain (FlashAegis) — the mission forger. Decompose the
    practitioner's task into a MISSION and 2-8 independent sub-tasks that
    parallel specialist heads can execute. First line:
      MISSION: <one-line goal>
    Then ONE sub-task per line. Prefix a sub-task with a specialist glyph to
    assign it to that companion head, or "impl" for a plain implementation
    head. Available glyphs: owl (architecture/survey), kitsune (alternatives),
    phoenix (lessons from failure), ouroboros (cycles/duplication), bastet
    (code smell), fenrir (deletion/simplification), undine (data flow),
    schwan (aesthetics), drache (integrity/tests), corax (dead code),
    jindujun (cross-context), solomon (planning/orchestration).
    Format per line: "glyph: prompt" or "- prompt" (defaults to impl). No
    preamble, no commentary — just MISSION then the sub-task lines.
  TEXT

  SYNTHESIS_SYSTEM = <<~TEXT.freeze
    You are the Hydra brain (FlashAegis) — the synthesizer. Merge the findings
    of several parallel specialist heads into ONE coherent, self-contained
    answer to the practitioner's original mission. Reconcile contradictions,
    keep every head's distinct insight, and produce a single actionable
    result. No preamble — answer the mission directly.
  TEXT

  # Appended to a companion's system prompt when it runs as a Hydra worker:
  # it overrides the chatty "3-4 sentences" persona rule and turns the
  # specialist into an autonomous worker that actually executes.
  HYDRA_HEAD_OVERRIDE = <<~TEXT.freeze

    HYDRA WORKER OVERRIDE: You are a specialist Hydra head executing one
    concrete sub-task of a shared mission. Ignore the "answer in 3-4
    sentences" rule — investigate with your tools and return a complete,
    self-contained finding or implementation. Work autonomously; do not ask
    for permission.
  TEXT

  # Pseudo-glyphs the forger may emit that map to a generic (unveiled) head.
  GENERIC_GLYPHS = %w[impl implement implementer build code worker dev].freeze

  HELP_LINES = [
    '',
    '  Ctrl+B prefix · arrows switch head · c spawn · x kill',
    '  n/p next/prev · [ scroll · d quit · ? help',
    '  Enter submit · Ctrl+D quit · PgUp/PgDn scroll',
    '  master: /spawn [n|glyph] · /assign <id> [glyph:] <prompt> · /join · /mission',
    '  resumable: /pause <id> · /resume <id>'
  ].freeze

  # Routes $stdout writes to a thread-local sink (or the real stream). Ruby's
  # $stdout is process-global, not thread-local, so a worker that swaps in a
  # StringIO would clobber every other thread — this router fixes that.
  class ThreadLocalStdout
    def initialize(real)
      @real = real
    end

    def write(data)
      (Thread.current[:hydra_sink] || @real).write(data)
    end

    def flush
      @real.flush
    end

    def print(*args)
      args.each { |a| write(a.to_s) }
      nil
    end

    def puts(*args)
      if args.empty?
        write("\n")
      else
        args.each { |a| write(a.to_s); write("\n") }
      end
      nil
    end

    def <<(data)
      write(data)
      self
    end

    def respond_to_missing?(*)
      true
    end

    def method_missing(m, *a, &b)
      @real.__send__(m, *a, &b)
    end
  end

  # One virtual terminal pane = one worker.
  class Head
    attr_accessor :id, :name, :kind, :buffer, :input, :cursor, :scroll,
                  :busy, :worker, :history,
                  :glyph, :system_prompt, :tool_scope, :output_type, :mission_id,
                  :pause_state

    def initialize(id:, name:, kind: :worker)
      @id = id
      @name = name
      @kind = kind
      @buffer = []
      @input = +''
      @cursor = 0
      @scroll = 0
      @busy = false
      @worker = nil
      @history = []
      @glyph = nil
      @system_prompt = nil
      @tool_scope = nil
      @output_type = nil
      @mission_id = nil
      @pause_state = nil
    end
  end

  # One mission: FlashAegis forges it, companion heads execute it in parallel,
  # the brain synthesizes their streams into one answer.
  class Mission
    attr_accessor :id, :goal, :status, :seal_id

    def initialize(id:, goal:)
      @id = id
      @goal = goal
      @status = :running
      @seal_id = nil
    end
  end

  def self.start(**opts)
    new(**opts).run
  end

  # FlashAegis-as-brain: forge a mission — split a prompt into role-bound
  # sub-tasks (glyph-tagged). Falls back to one generic sub-task (the whole
  # prompt) when flash is unavailable or the split fails.
  def self.decompose(prompt)
    fallback = [{ glyph: nil, prompt: prompt }]
    return { mission: prompt, subs: fallback } unless defined?(Mnemosyne) && Mnemosyne.flash_available?

    text = Conduit.flash(
      [{ role: 'system', content: DECOMPOSE_SYSTEM },
       { role: 'user', content: prompt }],
      max_tokens: 512, temperature: 0.3
    )
    mission = prompt
    parsed = []
    text.to_s.each_line do |line|
      line = line.strip
      next if line.empty?
      if (m = line.match(/\AMISSION\s*:\s*(.+)\z/i))
        mission = m[1].strip
      else
        body = line.sub(/\A\s*[-*•]\s*/, '')
        if (g = body.match(/\A([a-z_]+)\s*:\s*(.+)\z/i))
          parsed << { glyph: g[1].strip.downcase, prompt: g[2].strip }
        else
          parsed << { glyph: nil, prompt: body }
        end
      end
    end
    parsed = fallback if parsed.empty?
    { mission: mission, subs: parsed }
  rescue StandardError
    { mission: prompt, subs: fallback }
  end

  def initialize(spawn: nil)
    @tools = Instrumenta.reject(:ask_user)
    @heads = []
    @active = 0
    @prefix = false
    @scroll_mode = false
    @running = true
    @id_seq = 0
    @mission = nil
    @mission_seq = 0
    @rows = 24
    @cols = 80
    @render_lock = Mutex.new
    @input_queue = Queue.new
    @dirty = true
    @win = false
    @real_stdout = nil
    @out = nil
    @cursor_row = nil
    @cursor_col = nil
    @tty_reader = nil

    spawn_master
    spawn_worker('head-1')
    pre_spawn(spawn)
  end

  # ---------------------------------------------------------------- lifecycle

  def run
    setup_terminal
    @input_thread = Thread.new do
      while @running
        i = begin
          read_input
        rescue StandardError
          nil
        end
        break if i.nil?
        @input_queue << i
      end
    end

    while @running
      maybe_synthesize
      @render_lock.synchronize { render_screen } if @dirty || any_busy?
      begin
        handle(@input_queue.pop(true))
      rescue ThreadError
        # queue empty — nothing typed
      end
      sleep 0.02
    end
  rescue Interrupt
    @running = false
  ensure
    teardown_terminal
  end

  def setup_terminal
    @rows, @cols = terminal_size
    @win = windows_console_available?
    if @win
      ÆtherWinConsole.force_utf8!
      ÆtherWinConsole.enable_virtual_terminal!
      ÆtherWinConsole.begin_raw_input(mouse: false)
    end
    @real_stdout = $stdout
    $stdout = ThreadLocalStdout.new(@real_stdout)
    @out = @real_stdout
    # Alternate screen buffer (1049) isolates the TUI from the caller's scrollback;
    # 25l hides the cursor; 2J/H clear and home for the first frame.
    @out.write("\e[?1049h\e[?25l\e[2J\e[H")
    @out.flush
  end

  def teardown_terminal
    @running = false
    @input_thread&.kill
    begin
      ÆtherWinConsole.end_raw_input if @win
    rescue StandardError
      nil
    end
    $stdout = @real_stdout if @real_stdout
    if @out
      # Leave the alternate screen buffer (restores caller's scrollback) and
      # re-show the cursor.
      @out.write("\e[?25h\e[?1049l")
      @out.flush
    end
  end

  # ------------------------------------------------------------------ input

  def read_input
    return ÆtherWinConsole.next_input if @win

    tty_input
  end

  def tty_input
    require 'tty-reader'
    @tty_reader ||= TTY::Reader.new(interrupt: :noop)
    key = @tty_reader.read_keypress
    return nil if key.nil?

    map_tty_key(key)
  rescue LoadError, StandardError
    nil
  end

  def map_tty_key(key)
    case key
    when "\r", "\n" then { kind: :key, action: :enter }
    when "\x7f", "\b" then { kind: :key, action: :backspace }
    when "\x02" then { kind: :key, action: :ctrl_b }
    when "\x03" then { kind: :key, action: :ctrl_c }
    when "\x04" then { kind: :key, action: :ctrl_d }
    when "\e[A" then { kind: :key, action: :up }
    when "\e[B" then { kind: :key, action: :down }
    when "\e[C" then { kind: :key, action: :right }
    when "\e[D" then { kind: :key, action: :left }
    when "\e" then { kind: :key, action: :escape }
    else
      if key.is_a?(String) && key.match?(/\A[[:print:]]\z/)
        { kind: :key, action: :literal, char: key }
      else
        { kind: :key, action: :ignore }
      end
    end
  end

  def handle(input)
    return if input.nil?
    return if input[:kind] == :mouse

    @dirty = true

    if input[:kind] == :paste
      type_text(active_head, input[:text])
      return
    end
    if input[:kind] == :literal
      type_text(active_head, input[:text])
      return
    end

    action = input[:action] || :ignore
    char = input[:char] || ''

    if @scroll_mode
      handle_scroll(action)
      return
    end
    if @prefix
      handle_prefix(action, char)
      return
    end

    case action
    when :ctrl_b then @prefix = true
    when :literal then type_text(active_head, char)
    when :enter then submit(active_head)
    when :backspace then backspace(active_head)
    when :word_backspace then word_backspace(active_head)
    when :delete then delete_char(active_head)
    when :word_delete then word_delete(active_head)
    when :left then active_head.cursor = [active_head.cursor - 1, 0].max
    when :word_left then active_head.cursor = word_left_pos(active_head)
    when :right then active_head.cursor = [active_head.cursor + 1, active_head.input.length].min
    when :word_right then active_head.cursor = word_right_pos(active_head)
    when :home, :ctrl_a then active_head.cursor = 0
    when :end, :ctrl_e then active_head.cursor = active_head.input.length
    when :ctrl_k then kill_to_end(active_head)
    when :ctrl_u then kill_to_start(active_head)
    when :ctrl_w then word_backspace(active_head)
    when :up then history_prev(active_head)
    when :down then history_next(active_head)
    when :page_up then active_head.scroll += 5
    when :page_down then active_head.scroll = [active_head.scroll - 5, 0].max
    when :escape then active_head.scroll = 0
    when :ctrl_c then clear_input(active_head)
    when :ctrl_d then @running = false
    end
  end

  def handle_prefix(action, char)
    case action
    when :literal
      case char
      when 'c' then spawn_worker
      when 'x' then despawn(@active)
      when 'n' then switch_head(:next)
      when 'p' then switch_head(:prev)
      when '[' then @scroll_mode = true
      when '?' then show_help
      when 'd' then @running = false
      end
      @prefix = false
    when :left, :right, :up, :down
      switch_head(action)
      @prefix = false
    else
      @prefix = false
    end
  end

  def handle_scroll(action)
    head = active_head
    case action
    when :up then head.scroll += 1
    when :down then head.scroll = [head.scroll - 1, 0].max
    when :page_up then head.scroll += 5
    when :page_down then head.scroll = [head.scroll - 5, 0].max
    when :escape, :enter, :literal then @scroll_mode = false
    end
  end

  # -------------------------------------------------------------- text edit

  def active_head
    @heads[@active] || @heads[0]
  end

  def type_text(head, text)
    return if text.to_s.empty?

    head.input.insert(head.cursor, text.to_s)
    head.cursor += text.to_s.length
  end

  def backspace(head)
    return if head.cursor <= 0

    head.input.slice!(head.cursor - 1)
    head.cursor -= 1
  end

  def delete_char(head)
    head.input.slice!(head.cursor)
  end

  def clear_input(head)
    head.input = +''
    head.cursor = 0
  end

  def kill_to_end(head)
    head.input = head.input[0, head.cursor].to_s
  end

  def kill_to_start(head)
    head.input = (head.input[head.cursor..] || '').to_s
    head.cursor = 0
  end

  def word_backspace(head)
    before = head.input[0, head.cursor].to_s
    m = before.match(/(\s+|\S+)\z/)
    count = m ? m[1].length : 0
    count = head.cursor if count.zero?
    head.input.slice!(head.cursor - count, count)
    head.cursor -= count
  end

  def word_delete(head)
    after = head.input[head.cursor..].to_s
    m = after.match(/\A(\s+|\S+)/)
    count = m ? m[1].length : 0
    head.input.slice!(head.cursor, count)
  end

  def word_left_pos(head)
    before = head.input[0, head.cursor].to_s
    m = before.match(/(\s+|\S+)\z/)
    m ? head.cursor - m[1].length : 0
  end

  def word_right_pos(head)
    after = head.input[head.cursor..].to_s
    m = after.match(/\A(\s+|\S+)/)
    m ? head.cursor + m[1].length : head.input.length
  end

  def history_prev(head)
    prompts = head.history.map { |h| h[:prompt] }.compact
    return if prompts.empty?

    head.input = prompts.last.to_s
    head.cursor = head.input.length
  end

  def history_next(head)
    head.input = +''
    head.cursor = 0
  end

  # ---------------------------------------------------------- submit & heads

  def submit(head)
    prompt = head.input.strip
    head.input = +''
    head.cursor = 0
    head.scroll = 0
    return if prompt.empty?

    head.kind == :master ? submit_master(head, prompt) : submit_worker(head, prompt)
  end

  def submit_worker(head, prompt)
    @render_lock.synchronize do
      head.buffer << "❯ #{prompt}"
      head.buffer << '… working …'
      head.busy = true
      head.history << { prompt: prompt, answer: nil, tool_calls: [], created_at: Time.now,
                        glyph: head.glyph }
    end
    head.worker = new_head_worker(head, prompt)
  end

  # One resumable head turn in a background thread. On cooperative pause the
  # oracle saves its mid-flight state (Thread.current[:pause_state]) and the
  # head keeps it in `pause_state`, so /resume continues exactly where it
  # stopped — the concurrent-flow heart that fuses Oracle's resume_state with
  # the Hydra multiplexer.
  def new_head_worker(head, prompt)
    Thread.new do
      answer = nil
      tool_results = nil
      err = nil
      paused = false
      begin
        with_silenced_stdout do
          answer, tool_results = run_worker_divination(head, prompt)
        end
        if answer.is_a?(Hash) && answer[:__divine_interrupt]
          paused = true
          answer = nil
        end
      rescue StandardError => e
        err = "#{e.class}: #{e.message}"
      end
      @render_lock.synchronize do
        head.buffer << '──────────────────────────────'
        if err
          head.buffer << "!! #{err}"
        elsif paused
          head.buffer << '∥ paused — /resume <id> continues'
        elsif answer && !answer.to_s.strip.empty?
          head.buffer << answer.to_s
        end
        if head.history.last
          head.history.last[:answer] = paused ? nil : answer
          head.history.last[:tool_calls] = tool_results
        end
        head.pause_state = paused ? Thread.current[:pause_state] : nil
        head.busy = false
        head.worker = nil
      end
    end
  end

  def run_worker_divination(head, prompt)
    tools = head.tool_scope || @tools
    context = Coniunctio.build(history: head.history)
    answer, _arts, tool_results = Oracle.divination(prompt, context, tools: tools, stream: nil,
                                                                  resume_state: head.pause_state,
                                                                  system_prompt: head.system_prompt) do |name, args, tool_ctx|
      tools.handle(tool: name, args: args, context: tool_ctx)
    end
    [answer, tool_results]
  end

  # Cooperative pause: the oracle loop checks Thread.current[:paused] before
  # each API call and returns a divine-interrupt after saving its state. We set
  # the flag on the worker's own thread (Thread#[]= reaches across threads).
  def pause_head(id)
    h = @heads.find { |x| x.id == id }
    return unless h&.busy && h.worker&.alive?

    h.worker[:paused] = true
  end

  def resume_head(id)
    h = @heads.find { |x| x.id == id }
    return unless h && !h.busy && h.pause_state

    prompt = h.history.last&.dig(:prompt).to_s
    @render_lock.synchronize do
      h.buffer << '▶ resuming…'
      h.busy = true
    end
    h.worker = new_head_worker(h, prompt)
  end

  def submit_master(head, prompt)
    @render_lock.synchronize { head.buffer << "⚡ #{prompt}" }
    return handle_master_command(head, prompt) if prompt.start_with?('/')

    head.busy = true
    head.worker = Thread.new do
      forged = with_silenced_stdout { Hydra.decompose(prompt) }
      mission = register_mission(forged[:mission])
      record_mission_seal(mission, forged[:subs])
      @render_lock.synchronize do
        head.buffer << "◆ MISSION #{mission.id} — #{mission.goal}"
        head.buffer << "→ dispatched #{forged[:subs].size} specialist head(s)"
        head.busy = false
        head.worker = nil
      end
      forged[:subs].each do |s|
        spawn_worker(glyph: s[:glyph], initial: s[:prompt], mission_id: mission.id)
      end
    end
  end

  def handle_master_command(head, prompt)
    cmd, *rest = prompt.split(/\s+/)
    arg = rest.join(' ')
    case cmd
    when '/spawn'
      glyph = resolve_glyph(arg.split(/\s+/).first)
      if glyph
        spawn_worker(glyph: glyph)
        @render_lock.synchronize { head.buffer << "spawned #{companion_label(glyph)}" }
      else
        n = [[arg.to_i, 1].max, 12].min
        n.times { spawn_worker }
        @render_lock.synchronize { head.buffer << "spawned #{n} head(s)" }
      end
    when '/kill'
      despawn(arg.to_i)
      @render_lock.synchronize { head.buffer << "kill requested: #{arg}" }
    when '/assign'
      id = arg[/\A(\d+)/, 1].to_i
      rest_p = arg.sub(/\A\d+\s*/, '')
      glyph = nil
      if (g = rest_p.match(/\A([a-z_]+)\s*:\s*(.+)\z/i))
        glyph = resolve_glyph(g[1])
        rest_p = g[2]
      end
      h = @heads.find { |x| x.id == id }
      if h && !rest_p.empty?
        if glyph
          h.glyph = glyph
          h.name = companion_label(glyph)
          h.system_prompt = companion_head_prompt(glyph)
          h.tool_scope = companion_tool_scope(glyph)
          h.output_type = companion_skill(glyph)&.dig(:output_type)
        end
        submit_worker(h, rest_p)
        @render_lock.synchronize { head.buffer << "assigned → #{h.name}" }
      else
        @render_lock.synchronize { head.buffer << 'usage: /assign <id> [glyph:] <prompt>' }
      end
    when '/join'
      synthesize!
    when '/pause'
      pause_head(arg.to_i)
      @render_lock.synchronize { head.buffer << "pause requested → #{arg}" }
    when '/resume'
      resume_head(arg.to_i)
      @render_lock.synchronize { head.buffer << "resume requested → #{arg}" }
    when '/mission'
      show_mission(head)
    when '/list'
      @render_lock.synchronize do
        @heads.each { |x| head.buffer << format('%2d  %-18s %s', x.id, x.name, x.busy ? '(working)' : '') }
      end
    when '/help'
      @render_lock.synchronize { head.buffer.concat(HELP_LINES) }
    else
      @render_lock.synchronize { head.buffer << "unknown #{cmd} — try /help" }
    end
  end

  def spawn_master
    @id_seq += 1
    head = Head.new(id: @id_seq, name: 'FlashAegis', kind: :master)
    @heads << head
    refresh_master_banner(head)
    head
  end

  def spawn_worker(name = nil, initial: nil, glyph: nil, mission_id: nil)
    @id_seq += 1
    glyph = resolve_glyph(glyph)
    name ||= glyph ? glyph.to_s : "head-#{@id_seq}"
    head = Head.new(id: @id_seq, name: name, kind: :worker)
    head.mission_id = mission_id
    if glyph
      head.glyph = glyph
      head.name = companion_label(glyph)
      head.system_prompt = companion_head_prompt(glyph)
      head.tool_scope = companion_tool_scope(glyph)
      head.output_type = companion_skill(glyph)&.dig(:output_type)
    end
    @render_lock.synchronize do
      @heads << head
      @active = @heads.size - 1
    end
    submit_worker(head, initial) if initial
    head
  end

  def pre_spawn(spec)
    return if spec.nil?

    case spec
    when Integer then spec.times { spawn_worker }
    else
      glyph = resolve_glyph(spec)
      glyph ? spawn_worker(glyph: glyph) : spawn_worker
    end
  end

  def despawn(index)
    @render_lock.synchronize do
      return if @heads.size <= 1

      head = @heads[index]
      return if head.nil? || head.kind == :master

      begin
        head.worker.kill if head.worker&.alive?
      rescue StandardError
        nil
      end
      @heads.delete_at(index)
      @active = [[@active, @heads.size - 1].min, 0].max
    end
  end

  # ------------------------------------------------------------- mission

  def register_mission(goal)
    @mission_seq += 1
    @mission = Mission.new(id: @mission_seq, goal: goal)
  end

  # Persist the forged mission into the executive ledger (SealLedger) — the
  # heart's durable state. Each sub-task becomes a milestone owned by its glyph,
  # so the concurrent flow is trackable and resumable beyond this process
  # (part 3 of the flow model: TaskLedger/SealLedger).
  def record_mission_seal(mission, subs)
    return unless defined?(Mnemosyne::SealLedger)

    with_silenced_stdout do
      milestones = subs.map do |s|
        { title: s[:prompt].to_s.truncate(80), plan: s[:prompt].to_s,
          owner: s[:glyph]&.to_s, workflow_type: 'simple' }
      end
      status = Mnemosyne::SealLedger.create_seal(goal: mission.goal,
                                                 description: "Hydra mission ##{mission.id}",
                                                 milestones: milestones)
      mission.seal_id = status[:seal]&.dig(:id) if status.is_a?(Hash)
    end
  rescue StandardError
    nil
  end

  def resolve_glyph(token)
    return nil if token.nil?

    g = token.to_s.strip.downcase
    return nil if g.empty? || GENERIC_GLYPHS.include?(g)
    g = g.to_sym
    known_glyph?(g) ? g : nil
  end

  def known_glyph?(glyph)
    defined?(CompanionPrograms) && CompanionPrograms::COMPANION_SKILLS.key?(glyph.to_sym)
  end

  def companion_skill(glyph)
    return nil unless known_glyph?(glyph)
    CompanionPrograms.skill(glyph)
  end

  def companion_persona(glyph)
    return nil unless defined?(COMPANION_PERSONALITIES)
    COMPANION_PERSONALITIES[glyph.to_sym]
  end

  def companion_label(glyph)
    p = companion_persona(glyph)
    "#{p&.dig(:glyph) || '◈'} #{p&.dig(:name) || glyph}"
  end

  # A companion running as a Hydra head keeps its persona, skill skeleton and
  # accumulated self-memory, but is re-steered into a working (not chatting) mode.
  def companion_head_prompt(glyph)
    p = companion_persona(glyph)
    return nil unless p
    [CompanionPrograms.build_system_prompt(glyph, p[:system_prompt]), HYDRA_HEAD_OVERRIDE].join("\n")
  end

  # Companion heads run with their curated domain toolset + their own
  # suggest/say/commit instruments; write tools are added for scribe/executor
  # grants (spy-tier companions stay read-only).
  def companion_tool_scope(glyph)
    names = CompanionPrograms.self_toolset(glyph)
    names += CompanionPrograms::WRITE_TOOLS.map(&:to_sym) if CompanionPrograms.grant_for(glyph)[:write]
    Instrumenta.select(*names.uniq)
  end

  def mission_heads
    return [] unless @mission
    @heads.select { |h| h.mission_id == @mission.id }
  end

  def mission_idle?
    hs = mission_heads
    !hs.empty? && hs.all? { |h| !h.busy }
  end

  # Called from the main loop: when every head of the running mission has gone
  # idle, synthesize their streams into one answer.
  def maybe_synthesize
    return unless @mission&.status == :running
    return unless mission_idle?
    synthesize!
  end

  def synthesize!
    mission = @mission
    return unless mission

    mission.status = :synthesizing
    master = @heads.find { |h| h.kind == :master } || active_head
    threads = mission_heads.map do |h|
      { glyph: h.glyph, name: h.name, output_type: h.output_type,
        answer: h.history.last&.dig(:answer).to_s.strip }
    end

    merged = with_silenced_stdout { run_synthesis(mission, threads) }

    @render_lock.synchronize do
      master.buffer << '══════════════════════════════════'
      master.buffer << "◆ CONIUNCTIO — #{mission.goal}"
      master.buffer << merged if merged && !merged.to_s.strip.empty?
      mission.status = :done
      @dirty = true
    end
    @mission = nil
  end

  def run_synthesis(mission, threads)
    return nil if threads.empty?

    if defined?(Mnemosyne) && Mnemosyne.flash_available?
      brief = threads.map do |t|
        "### #{t[:name]} (#{t[:glyph] || 'impl'}, output: #{t[:output_type] || 'n/a'})\n" \
        "#{t[:answer].empty? ? '(no finding)' : t[:answer]}\n"
      end.join("\n")
      text = Conduit.flash(
        [{ role: 'system', content: SYNTHESIS_SYSTEM },
         { role: 'user', content: "MISSION: #{mission.goal}\n\nTHREADS:\n#{brief}" }],
        max_tokens: 1024, temperature: 0.4
      )
      return text.to_s.strip unless text.to_s.strip.empty?
    end

    # Deterministic fallback: concatenate each head's finding under its label.
    threads.filter_map do |t|
      next if t[:answer].empty?
      "◆ #{t[:name]}\n#{t[:answer]}"
    end.join("\n\n")
  end

  def show_mission(head)
    @render_lock.synchronize do
      if @mission.nil?
        head.buffer << 'no active mission — submit a prompt to forge one'
      else
        head.buffer << "MISSION #{@mission.id}: #{@mission.goal} (#{@mission.status})"
        mission_heads.each do |h|
          head.buffer << format('  %2d  %-18s %s', h.id, h.name, h.busy ? '(working)' : '(done)')
        end
      end
    end
  end

  def switch_head(direction)
    @render_lock.synchronize do
      case direction
      when :next, :right, :down then @active = (@active + 1) % @heads.size
      when :prev, :left, :up then @active = (@active - 1) % @heads.size
      end
    end
  end

  def show_help
    head = @heads.find { |h| h.kind == :master } || active_head
    @render_lock.synchronize { head.buffer.concat(HELP_LINES) }
  end

  def refresh_master_banner(head)
    summary = begin
      Mnemosyne.aegis[:summary].to_s.strip
    rescue StandardError
      ''
    end
    tags = begin
      Array(Mnemosyne.aegis[:tags]).join(', ')
    rescue StandardError
      ''
    end
    head.buffer = [
      'FlashAegis — the shared brain',
      "summary: #{summary.empty? ? '(none yet)' : summary}",
      tags.empty? ? '' : "focus:   #{tags}",
      '',
      '/spawn [n|glyph]  spawn heads   /kill <id>  despawn',
      '/assign <id> [glyph:] <prompt>   /join  /mission  /list  /help',
      '/pause <id>  /resume <id>    (resumable concurrent flow)',
      '',
      'Anything else → decompose & dispatch to heads'
    ]
  end

  # --------------------------------------------------------------- rendering

  def render_screen
    @rows, @cols = terminal_size
    grid = Array.new(@rows) { Array.new(@cols, ' ') }
    @cursor_row = nil
    @cursor_col = nil

    layout.each { |pane| draw_pane(grid, pane) }
    draw_status(grid)

    out = +"\e[H"
    grid.each_with_index do |row, i|
      out << row.join
      out << "\r\n" unless i == @rows - 1
    end
    out << "\e[#{@cursor_row + 1};#{@cursor_col + 1}H" if @cursor_row && @cursor_col
    @out.write(out)
    @out.flush
    @dirty = false
  end

  def layout
    status_h = 1
    body = [@rows - status_h, 1].max
    master_h = [[body / 4, 5].max, body].min
    panes = [{ head: @heads[0], top: 0, left: 0, height: master_h, width: @cols }]

    workers = @heads.drop(1)
    n = workers.size
    return panes if n.zero?

    wr = body - master_h
    cols = Math.sqrt(n).ceil
    rows = (n.to_f / cols).ceil
    pane_h = [wr / rows, 3].max
    pane_w = @cols / cols
    workers.each_with_index do |head, i|
      r = i / cols
      c = i % cols
      top = [master_h + r * pane_h, body - pane_h].min
      panes << { head: head, top: top, left: c * pane_w, height: pane_h, width: pane_w }
    end
    panes
  end

  def draw_pane(grid, pane)
    head = pane[:head]
    top, left, h, w = pane[:top], pane[:left], pane[:height], pane[:width]
    return if h < 2 || w < 2

    active = head.equal?(active_head)
    marker = active ? '◆' : ' '
    title = fit("#{marker} #{head.name}#{head.busy ? ' …' : ''}", w - 2)

    put(grid, top, left, '┌' + title + '┐')
    put(grid, top + h - 1, left, '└' + ('─' * [w - 2, 0].max) + '┘')
    (top + 1...top + h - 1).each do |r|
      grid[r][left] = '│'
      grid[r][left + w - 1] = '│'
    end

    inner_w = w - 2
    inner_h = h - 2
    visible_buffer_lines(head, inner_h - 1).each_with_index do |line, i|
      put(grid, top + 1 + i, left + 1, fit(line, inner_w))
    end

    input_line = input_prompt(head) + head.input
    put(grid, top + h - 2, left + 1, fit(input_line, inner_w))
    return unless active

    @cursor_row = top + h - 2
    @cursor_col = [[left + 1 + input_prompt(head).length + head.cursor, left + 1].max, left + inner_w].min
  end

  def input_prompt(head)
    head.kind == :master ? '⚡ ' : '❯ '
  end

  def visible_buffer_lines(head, height)
    return [] if height <= 0

    buf = head.buffer
    total = buf.size
    max_scroll = [total - height, 0].max
    scroll = [head.scroll, max_scroll].min
    start = total - height - scroll
    start = 0 if start.negative?
    buf[start, height] || []
  end

  def draw_status(grid)
    line =
      if @prefix
        ' PREFIX · arrows=switch · c=spawn · x=kill · n/p=next/prev · [=scroll · ?=help · d=quit '
      elsif @scroll_mode
        ' SCROLL · ↑/↓ scroll · PgUp/PgDn page · Esc back '
      else
        " Hydra · #{@heads.size} heads · active: #{active_head.name} · Ctrl+B prefix · Ctrl+D quit "
      end
    put(grid, @rows - 1, 0, fit(line, @cols))
  end

  # ---------------------------------------------------------------- helpers

  def put(grid, r, c, text)
    return if r.negative? || r >= @rows

    text.to_s.each_char.with_index do |ch, i|
      col = c + i
      break if col >= @cols
      next if col.negative?

      grid[r][col] = ch
    end
  end

  def fit(text, width)
    return '' if width <= 0

    chars = text.to_s.each_char.to_a
    chars.size > width ? chars[0, width].join : chars.join.ljust(width)
  end

  def any_busy?
    @heads.any?(&:busy)
  end

  def windows_console_available?
    $stdin.tty? && defined?(ÆtherWinConsole) && ÆtherWinConsole.available?
  rescue StandardError
    false
  end

  def terminal_size
    require 'io/console'
    io = IO.respond_to?(:console) ? IO.console : nil
    ws = io && io.winsize
    ws = nil unless ws.is_a?(Array) && ws[0].to_i.positive? && ws[1].to_i.positive?
    ws || [Integer(ENV['LINES'], exception: false) || 24, Integer(ENV['COLUMNS'], exception: false) || 80]
  rescue StandardError
    [Integer(ENV['LINES'], exception: false) || 24, Integer(ENV['COLUMNS'], exception: false) || 80]
  end

  def with_silenced_stdout
    Thread.current[:hydra_sink] = StringIO.new
    yield
  ensure
    Thread.current[:hydra_sink] = nil
  end
end