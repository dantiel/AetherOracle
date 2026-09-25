#!/usr/bin/env ruby
# frozen_string_literal: true

# Force UTF-8 regardless of the (possibly minimal) launch environment. Without
# LANG/LC_ALL set, Ruby defaults to US-ASCII and the brain's emoji/glyph-laden
# prompts raise Encoding::CompatibilityError when joined.
ENV['LANG'] ||= 'en_US.UTF-8'
ENV['LC_ALL'] ||= 'en_US.UTF-8'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Æther Standalone Daemon — full-brain adapter.
#
# A 1:1 mirror of the TextMate plugin's Ruby intelligence core, exposed over a
# framed JSON protocol on STDIN/STDOUT. This daemon does NOT require limen.rb
# (which redirects stdout) or cli.rb (which auto-runs the TextMate loop).
#
# Wire protocol (newline-delimited JSON frames):
#   inbound:  { "command": String, "arguments": Hash, "request_id": Integer }
#   outbound ready: { "type":"ready", "version":..., "components":[...] }
#   outbound stream: { "type":"stream", "method":"status", "payload":{ "type":KIND, "data":{...}, ... } }
#   outbound result: { "type":"result", "request_id":N, "success":Bool, "result":..., "error":... }

require 'securerandom'
require 'fileutils'
require 'thread'
require 'socket'

# Resolve the project root. Swift passes AETHER_PROJECT_ROOT; fall back to cwd.
# The root is MUTABLE: `activate_context` re-points it when the user opens a
# file/folder from another project, making the daemon polymorphic at runtime
# (the whole window inherits the new project's identity — "ICH bin der ÆTHER").
$project_root = ENV['AETHER_PROJECT_ROOT'] || Dir.pwd

# Point runtime data (memory db, logs, pids) at the active project's `.aether/`
# directory. Kept in a method so context switches re-resolve the paths without
# restarting the daemon. `.aethercodex` remains the pure configuration file.
def aether_data_dir(root = $project_root)
  File.join(root, '.aether')
end

def apply_project_root(root)
  $project_root = File.expand_path(root)
  Dir.chdir($project_root)
  ENV['AETHER_PROJECT_ROOT'] = $project_root
  ENV['TM_PROJECT_DIRECTORY'] = $project_root
  ENV['AETHER_TM_AI'] = aether_data_dir + '/'
  ENV['AETHER_MEMORY_DB'] = File.join(aether_data_dir, 'mnemosyne.db')
end

apply_project_root($project_root)

# Reserve the real stdout for the framed wire protocol, and divert the Ruby
# brain's debug `puts` output to stderr so it cannot corrupt the protocol.
# HorologiumAeternum and the brain use `puts` for logging (harmless in TextMate,
# where limen.rb redirects stdout); here we must keep stdout pure.
FRAME_IO = STDOUT
FRAME_IO.sync = true
$stderr.sync = true
$stdout = $stderr

# Serializes every frame written to STDOUT so the worker thread and the main
# thread cannot interleave partial JSON lines. Frames are newline-delimited; a
# torn write would corrupt the protocol for the Swift reader.
FRAME_MUTEX = Mutex.new

# SIGTERM (Swift `Process.terminate`) must reliably end the daemon even while the
# worker thread is mid-computation. Ruby's default disposition already does this,
# but an explicit trap guards against any gem/extension masking it and mirrors
# limen.rb's `trap('TERM') { exit }`. `exit` still runs `at_exit` (socket cleanup).
trap('TERM') { exit }
trap('INT')  { exit }

# Death evidence: log every process exit to stderr (drained by the Swift bridge
# into daemonLog) so a crash or signal death is never silent.
at_exit { warn "[AETHER-DAEMON] exit (pid #{Process.pid})" }

# Point bundler at this Ruby tree's Gemfile so the full dependency set resolves
# regardless of the process working directory.
RUBY_DIR = File.expand_path(__dir__)
# Use explicit empty-checks (not `||=`) — an exported-but-empty BUNDLE_* var is
# truthy in Ruby and would otherwise pin bundler to a nonexistent Gemfile/path.
ENV['BUNDLE_GEMFILE'] = File.join(RUBY_DIR, 'Gemfile') if ENV['BUNDLE_GEMFILE'].to_s.strip.empty?
ENV['BUNDLE_PATH'] = File.join(RUBY_DIR, '.vendor_bundle') if ENV['BUNDLE_PATH'].to_s.strip.empty?
# Pin GEM_HOME/GEM_PATH to the vendored bundle (mirrors boot.rb) so git-sourced
# gems (htmldiff) and platform binaries resolve regardless of the shell's gemrc
# or RVM state. Without this, bundler may activate gems from a foreign GEM_HOME
# and miss the git checkout under bundler/gems/.
ENV['GEM_HOME'] = ENV['BUNDLE_PATH']
ENV['GEM_PATH'] = ENV['BUNDLE_PATH']
# Call Bundler.setup explicitly instead of `require 'bundler/setup'`: the latter
# silently no-ops when Bundler::SharedHelpers.in_bundle? is false (no .bundle dir
# in a fresh checkout), which would leave git-sourced gems (htmldiff) unresolvable.
require 'bundler'
Bundler.ui.silence { Bundler.setup }
require 'json'

# Load the full brain. Order matters only for clarity; require_relative dedups.
require_relative 'config'
require_relative 'mnemosyne/mnemosyne'
require_relative 'mnemosyne/seal_ledger'
require_relative 'oracle/oracle'
require_relative 'oracle/coniunctio'
require_relative 'oracle/aetherflux'
require_relative 'instrumentarium/instrumenta'
require_relative 'instrumentarium/prima_materia'
require_relative 'instrumentarium/horologium_aeternum'
require_relative 'magnum_opus/magnum_opus_engine'
require_relative 'shell_session'

# PipeStream adapts HorologiumAeternum's WebSocket-style sink to STDOUT frames.
# HorologiumAeternum.send builds a JSON string {"method":...,"result":{...}}
# and calls @websocket.send(payload). We re-frame it as a typed stream event.
class PipeStream
  def initialize(out = FRAME_IO)
    @out = out
  end

  def send(payload)
    event = begin
      JSON.parse(payload)
    rescue StandardError
      {}
    end
    frame = {
      type:       'stream',
      method:     event['method'],
      payload:    event['result'],
      request_id: Thread.current[:aether_request_id]
    }
    FRAME_MUTEX.synchronize do
      @out.write(frame.to_json + "\n")
      @out.flush
    end
  rescue StandardError => e
    warn "PipeStream#send failed: #{e.message}"
  end
end

class StandaloneDaemon
  # Commands that must stay responsive even while a heavy computation runs.
  # They execute on the main thread immediately; `interrupt` and
  # `activate_context` additionally set the worker's cooperative pause flag.
  # Control commands answer inline on the reader thread, so they stay responsive
  # while the single worker runs a heavy oracle turn. Only lightweight ledger
  # writes belong here — `execute_task`/`evaluate_task` must stay queued (they
  # own the worker), but `create_task` is a plain Mnemosyne insert and must never
  # wait behind a running computation: the UI's confirm has to answer at once.
  CONTROL_COMMANDS = %w[
    ping activate_context interrupt aegis history get_note remove_note
    list_tasks create_task remove_task recall user_response
    seal_create seal_list seal_status seal_delegate
    task_detail
  ].freeze

  def initialize
    @stream = PipeStream.new
    HorologiumAeternum.set_websocket(@stream)
    @engine = MagnumOpusEngine.new(mnemosyne: Mnemosyne, aetherflux: Aetherflux)
    @queue = Queue.new
    @worker_thread = nil
    @shell = ShellSession.new($project_root)
    # The agent's run_command instrument resolves its cwd through this handle,
    # coupling the user's CLI and the model's shell into one filesystem truth.
    $aether_shell = @shell
    @running = true
    start_worker
  end

  def emit(obj)
    # The sink is thread-local: STDIN/STDOUT mode writes to FRAME_IO; ÆtherLimen
    # socket mode writes to the connection's socket (set on the reader thread and
    # carried into the worker). One brain, many eyes, one sink per request.
    sink = Thread.current[:aether_sink] || FRAME_IO
    FRAME_MUTEX.synchronize do
      sink.write(obj.to_json + "\n")
      sink.flush
    end
  rescue StandardError => e
    # A broken stdout/socket (Swift closed the pipe, client dropped) must never
    # kill the daemon's main thread or starve the worker. Log to stderr — the
    # Swift bridge drains it into daemonLog — so the death is never silent.
    warn "[AETHER-DAEMON] emit failed: #{e.class}: #{e.message}"
  end

  # The companion pantheon for Swift: key/glyph/name/temperature/thinking plus
  # the recipe's domain (trigger/grant/reach/tools), so the companion menu can
  # show each voice's abilities and permission without duplicating the recipes.
  # One roster, two worlds — correspondence, not duplication.
  def companion_roster
    COMPANION_PERSONALITIES.map do |key, p|
      t = COMPANION_TEMPERAMENTS[key] || {}
      recipe = (defined?(CompanionPrograms) && CompanionPrograms::COMPANION_RECIPES[key]) || {}
      {
        key: key.to_s,
        glyph: p[:glyph],
        name: p[:name],
        temperature: t[:temperature],
        thinking: t[:thinking],
        trigger: recipe[:trigger].to_s,
        grant: recipe[:grant].to_s,
        reach: recipe[:reach].to_s,
        tools: Array(recipe[:tools])
      }
    end
  end

  # Single worker consumes heavy requests serially (FIFO). No parallel network
  # calls, no competing SQLite writes, no $project_root races — linear history.
  # Each turn breathes its own ShellSession branch, forked from the merged cwd;
  # the agent's run_command mutates that branch and it merges back on completion.
  def start_worker
    @worker_thread = Thread.new do
      Thread.current.report_on_exception = true
      begin
        loop do
          request, request_id, sink = @queue.pop
          break if request == :shutdown

        Thread.current[:paused] = false
        Thread.current[:aether_request_id] = request_id
        Thread.current[:aether_sink] = sink

        turn_shell = @shell.branch
        $aether_shell = turn_shell

        begin
          result = dispatch(request['command'], request['arguments'] || {})
          emit(type: 'result', request_id: request_id, success: true, result: result)
        rescue Exception => e
          # Purificatio: StandardError misses SyntaxError/LoadError/NoMemoryError
          # & co. — a SyntaxError from eval'd tooling would otherwise kill the
          # worker silently (no result, no recover) and hang Swift until its
          # lease. Fatal shutdown signals still propagate so the daemon can exit.
          raise if e.is_a?(SystemExit) || e.is_a?(SignalException)

          emit(type: 'result', request_id: request_id, success: false,
               error: "#{e.class}: #{e.message}")
          # Riss §7: when a turn breaks (lease expiry / error), the companion
          # becomes the next chapter's beginning — surface a one-click recovery
          # macro instead of a dead end. The last intention lives in Aegis.
          begin
            last_intent = (Mnemosyne.aegis || {})[:summary].to_s
            emit(type: 'recover_suggestion',
                 request_id: request_id,
                 glyph: '🦊',
                 prompt: 'Hier riss der Faden — weiterweben?',
                 action: 'recover_last_intent',
                 last_intent: last_intent[0, 400])
          rescue Exception
            # Best-effort: the failure result is already emitted. Swallowing even
            # non-StandardError here keeps the worker alive for the next turn.
            nil
          end
        ensure
          # Merge the turn's branch back into the trunk unless a context switch
          # replaced it mid-flight (activate_context re-points @shell to the new
          # project's cwd; the stale branch must not clobber it).
          @shell.merge_from(turn_shell) if $aether_shell.equal?(turn_shell)
          $aether_shell = @shell
          Thread.current[:paused] = false
          Thread.current[:aether_request_id] = nil
        end
      end
      rescue Exception => e
        warn "[AETHER-DAEMON] worker died: #{e.class}: #{e.message}"
        warn(e.backtrace.join("\n")) if e.backtrace
        # A dead worker = a zombie daemon (queued turns would hang forever). Exit
        # loudly so Swift sees process death and revives with backoff instead of
        # wedging until the request lease expires.
        exit!(1)
      end
    end
  end

  # Transport dispatch: `--listen SOCKET` runs the ÆtherLimen background service
  # (Unix-domain socket, survives the app); otherwise the daemon speaks the
  # original framed JSON protocol over STDIN/STDOUT (dev / spawn mode).
  def run
    if (idx = ARGV.index('--listen'))
      run_socket(ARGV[idx + 1])
    else
      run_stdio
    end
  end

  def run_stdio
    emit(type: 'ready', version: '3.0.0',
         components: %w[mnemosyne aegis oracle companions tasks instrumentarium magnum_opus flow cli],
         companions: companion_roster)

    while @running
      line = STDIN.gets
      break if line.nil?

      line = line.strip
      next if line.empty?

      begin
        request = JSON.parse(line)
        route_request(request)
      rescue JSON::ParserError => e
        emit(type: 'result', request_id: nil, success: false, error: "Invalid JSON: #{e.message}")
      rescue Exception => e
        raise if e.is_a?(SystemExit) || e.is_a?(SignalException)
        warn "[AETHER-DAEMON] main loop error: #{e.class}: #{e.message}"
      end
    end

    shutdown
  end

  # ÆtherLimen: a long-lived Unix-domain socket server. Each connection is a
  # window/client; the single worker serializes heavy turns, and control commands
  # stay responsive inline on each connection's reader thread. The shared @shell,
  # $project_root and Mnemosyne are the one æther the windows breathe together.
  def run_socket(path)
    path = '/tmp/aether-limen.sock' if path.to_s.strip.empty?
    File.delete(path) if File.exist?(path)
    server = UNIXServer.new(path)
    at_exit { File.delete(path) rescue nil }
    warn "[AETHER-LIMEN] listening on #{path}"

    loop do
      socket = server.accept
      Thread.new(socket) do |sock|
        Thread.current[:aether_sink] = sock
        emit(type: 'ready', version: '3.0.0',
             components: %w[mnemosyne aegis oracle companions tasks instrumentarium magnum_opus flow cli],
             companions: companion_roster)
        while (line = sock.gets)
          line = line.strip
          next if line.empty?
          begin
            request = JSON.parse(line)
            route_request(request, sock)
          rescue JSON::ParserError => e
            emit(type: 'result', request_id: nil, success: false, error: "Invalid JSON: #{e.message}")
          end
        end
      ensure
        sock.close rescue nil
        Thread.current[:aether_sink] = nil
      end
    end
  end

  # Main-thread router. Control commands run inline (so `interrupt` and
  # `activate_context` stay responsive mid-computation); heavy commands are
  # queued for the single worker thread. This is the git-flow merge strategy:
  # control ops are rebased onto the live branch, heavy turns stay linear.
  def route_request(request, sink = nil)
    command = request['command']
    args = request['arguments'] || {}
    request_id = request['request_id']

    if command == 'interrupt'
      emit(type: 'result', request_id: request_id, success: true, result: interrupt_computation)
    elsif CONTROL_COMMANDS.include?(command)
      begin
        result = dispatch(command, args)
        emit(type: 'result', request_id: request_id, success: true, result: result)
      rescue Exception => e
        raise if e.is_a?(SystemExit) || e.is_a?(SignalException)
        emit(type: 'result', request_id: request_id, success: false,
             error: "#{e.class}: #{e.message}")
      end
    else
      @queue << [request, request_id, sink]
    end
  end

  def shutdown
    warn "[AETHER-DAEMON] shutdown (pid #{Process.pid})"
    @running = false
    @queue << [:shutdown, nil, nil]
    @worker_thread&.join(2)
  end

  def dispatch(command, args)
    case command
    when 'ping'
      { pong: true, time: Time.now.to_f, cwd: ($aether_shell || @shell).cwd }

    # -- Mnemosyne --
    when 'remember'
      Mnemosyne.remember(content: args['content'], links: args['links'], tags: args['tags'])
    when 'recall'
      Mnemosyne.recall_notes(args['query'].to_s, limit: args.fetch('limit', 5))
    when 'get_note'
      Mnemosyne.get_note(args['id'])
    when 'remove_note'
      Mnemosyne.remove_note(args['id'])
    when 'history'
      Mnemosyne.fetch_history(limit: args.fetch('limit', 7), include_tool_calls: args.fetch('include_tool_calls', false))

    # -- Aegis --
    when 'aegis'
      handle_aegis(args)

    # -- Oracle / chat / companions --
    when 'oracle', 'chat', 'conjuration'
      handle_oracle(args)
    when 'companion'
      handle_oracle(args.merge('companion' => (args['name'] || args['companion'])))

    # -- Magnum Opus task engine --
    when 'create_task'
      @engine.create_task(title: args.fetch('title'), plan: args.fetch('plan'),
                          workflow_type: args.fetch('workflow_type', 'full'))
    when 'execute_task'
      @engine.execute_task(args.fetch('id'))
    when 'evaluate_task'
      @engine.evaluate_task(args.fetch('id'))
    when 'task_detail'
      @engine.task_detail(args.fetch('id'))
    when 'list_tasks'
      Mnemosyne.manage_tasks(action: 'list')
    when 'remove_task'
      Mnemosyne.remove_task(args.fetch('id'))

    # -- Salomo Rex: the Siegel (executive plan ledger) --
    when 'seal_create'
      Mnemosyne::SealLedger.create_seal(goal: args.fetch('goal'),
                                        description: args['description'],
                                        milestones: args['milestones'] || [])
    when 'seal_list'
      Mnemosyne::SealLedger.list_seals
    when 'seal_status'
      Mnemosyne::SealLedger.seal_status(args.fetch('id'))
    when 'seal_delegate'
      Mnemosyne::SealLedger.delegate(args.fetch('task_id'), args['owner'])
    when 'seal_run'
      seal_run(args.fetch('id'), args['max_steps'])

    # -- Streaming user-response (destructive-tool confirmation) --
    when 'user_response'
      HorologiumAeternum.receive_user_response(args['uuid'], args['response'])
      { ok: true }

    # -- Metempsychosis --
    when 'metempsychosis'
      Mnemosyne.metempsychosis(**symbolize_keys(args))

    # -- Pythia CLI (polymorphic shell shared with the agent's run_command) --
    when 'cli'
      handle_cli(args)

    # -- Polymorphic context switch --
    when 'activate_context'
      activate_context(args['path'].to_s)

    # -- Interrupt the in-flight Oracle computation --
    when 'interrupt'
      interrupt_computation

    else
      { error: "Unknown command: #{command}" }
    end
  end

  # Salomo Rex' Autonomie-Loop: drive the critical path one bounded step at a time.
  # Executes the next unblocked milestone (simple workflow) and re-evaluates the
  # seal, repeating up to `max_steps`. Hermetically bounded — user-sovereign
  # progression, never a runaway loop. Failures mark the milestone and block its
  # dependents; the loop reports what it did and where the seal now stands.
  def seal_run(seal_id, max_steps = 1)
    max_steps = [[max_steps.to_i, 1].max, 8].min
    executed = []

    max_steps.times do
      status = Mnemosyne::SealLedger.seal_status(seal_id)
      break if status[:error]

      next_task = status[:next]
      break unless next_task

      begin
        @engine.execute_task(next_task[:id])
        executed << { id: next_task[:id], title: next_task[:title], status: 'completed' }
      rescue StandardError => e
        executed << { id: next_task[:id], title: next_task[:title],
                       status: 'failed', error: "#{e.class}: #{e.message}" }
      end
    end

    Mnemosyne::SealLedger.seal_status(seal_id).merge(executed: executed)
  end

  # Re-point the daemon at a different project root. The daemon is a singleton
  # process; switching context must (1) move the working directory, (2) re-resolve
  # the `.aether/` data paths, (3) reload the hierarchical config from the new
  # project, and (4) reset Mnemosyne so it re-opens the new memory db. Everything
  # else (Oracle, companions, tasks) reads CONFIG lazily and follows automatically.
  def activate_context(path)
    return { error: 'activate_context: no path given' } if path.to_s.strip.empty?

    # Cooperatively pause the in-flight computation so the context switch is not
    # racing a tool call. The worker notices the flag at the next loop boundary.
    pause_worker

    root = resolve_project_root(path)
    return { error: "No such path: #{path}" } unless root

    apply_project_root(root)
    CONFIG.reload! if CONFIG.respond_to?(:reload!)
    Mnemosyne.reset_connection! if Mnemosyne.respond_to?(:reset_connection!)
    @shell&.reset($project_root)
    # Re-point the active shell handle: any in-flight turn branch is stale now,
    # so the trunk and the instrument's handle both breathe the new project.
    $aether_shell = @shell

    {
      project_root: $project_root,
      name: CONFIG.project_name,
      config_path: File.exist?(File.join($project_root, '.aethercodex')) ? File.join($project_root, '.aethercodex') : nil,
      memory_db: CONFIG.memory_db_path
    }
  end

  # Set the worker's cooperative pause flag. The Oracle loop checks
  # Thread.current[:paused] at each boundary and returns a divine interrupt.
  def pause_worker
    t = @worker_thread
    t[:paused] = true if t && t.alive?
  end

  # Walk up from `path` (file or directory) to the nearest `.aethercodex`; if
  # none exists, the originally-opened directory becomes the project root. This
  # mirrors AetherContext.resolveRoot in Swift so both sides agree on identity.
  def resolve_project_root(path)
    path = File.expand_path(path)
    return nil unless File.exist?(path)

    opened_dir = File.directory?(path) ? path : File.dirname(path)
    current = opened_dir
    loop do
      candidate = File.join(current, '.aethercodex')
      return current if File.exist?(candidate)
      parent = File.dirname(current)
      return opened_dir if parent == current || parent.empty?
      current = parent
    end
  end

  # Best-effort cancellation of the running Oracle request. Aetherflux tracks the
  # active HorologiumAeternum token; signalling it lets the model stop cleanly
  # without killing the daemon, so the queued interjection can run next.
  def interrupt_computation
    t = @worker_thread
    if t && t.alive?
      t[:paused] = true
      { interrupted: true, queued: @queue.size }
    else
      { interrupted: false, note: 'no in-flight computation' }
    end
  end

  # The user's `$` command returns its result directly (the client renders the
  # CLI block from the result, including cwd + exit_status). The agent's
  # run_command tool keeps its own command_executing/completed stream events,
  # which the client renders as the *same* unified CLI block — two hands, one
  # interface, no double-render.
  def handle_cli(args)
    cmd = args['cmd'].to_s
    return { error: 'cli: no command given' } if cmd.strip.empty?
 
    ($aether_shell || @shell).run(cmd, timeout: args.fetch('timeout', 30))
  end

  def handle_aegis(args)
    case args['action']
    when 'get'
      Mnemosyne.restore_aegis
      Mnemosyne.aegis
    when 'notes'
      Mnemosyne.recall_aegis_notes(max_tokens: args['max_tokens'], max_content_length: args['max_content_length'])
    when 'update', 'unveil'
      Mnemosyne.unveil_aegis(
        summary: args['summary'],
        tags: args.fetch('tags', []),
        temperature: args.fetch('temperature', 1.0),
        thinking: args['thinking'],
        working_dir: args['working_dir']
      )
      { ok: true, aegis: Mnemosyne.aegis }
    else
      { error: "Unknown aegis action: #{args['action']}" }
    end
  end

  def handle_oracle(args)
    params = {}
    params[:prompt] = args['message'] || args['prompt'] if args['message'] || args['prompt']
    params[:messages] = args['messages'] if args['messages']
    params[:companion] = args['companion'] if args['companion']
    params[:active_companions] = args['active_companions'] if args['active_companions']
    params[:system_prompt] = args['system'] || args['system_prompt'] if args['system'] || args['system_prompt']
    params[:temperature] = args['temperature'] if args['temperature']
    params[:thinking] = args['thinking'] if args['thinking']
    params[:model] = args['model'] if args['model']
    params[:flash_auto] = true if args['flash_auto']
    params[:ephemeral] = true if args['ephemeral']
    params[:record] = args.fetch('record', false)
    params[:attachments] = args['attachments'] if args['attachments']
    params[:file] = args['file'] if args['file']
    params[:selection] = args['selection'] if args['selection']
    params[:history] = args.fetch('history', false)
    params[:suggestion_execution] = args['suggestion_execution'] if args.key?('suggestion_execution')

    context = args['context'] || {}
    context = context.merge(project_root: $project_root) unless context[:project_root] || context['project_root']

    Aetherflux.channel_oracle_divination(params, tools: Instrumenta, context: context)
  end

  private

  def symbolize_keys(hash)
    hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
  end
end

StandaloneDaemon.new.run