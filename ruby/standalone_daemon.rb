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

# Resolve the project root by DERIVING the context from where the daemon runs:
# walk up from Dir.pwd to the nearest config file (`.aethercodex` or
# `.aether_properties`). AETHER_PROJECT_ROOT is kept as an explicit override for
# the macOS/Swift bridge; on Windows and most hosts the context is simply the
# config file nearest the working directory.
def derive_project_root(start_dir = Dir.pwd)
  current = File.expand_path(start_dir)
  loop do
    return current if %w[.aethercodex .aether_properties].any? { |n| File.exist?(File.join(current, n)) }
    parent = File.dirname(current)
    return File.expand_path(start_dir) if parent == current || parent.empty?
    current = parent
  end
end

$project_root = ENV['AETHER_PROJECT_ROOT'] || derive_project_root(Dir.pwd)

# Point runtime data (memory db, logs, pids) at the active project's `.aether/`
# directory. Kept in a method so context switches re-resolve the paths without
# restarting the daemon. `.aethercodex` remains the pure configuration file.
def aether_data_dir(root = $project_root)
  File.join(root, '.aether')
end

def apply_project_root(root)
  root = File.expand_path(root)
  # A file path (the host passes the active document) cannot be a cwd;
  # resolve it to its containing directory before `Dir.chdir` (Errno::EINVAL).
  root = File.dirname(root) unless File.directory?(root)
  $project_root = root
  Dir.chdir($project_root)
  ENV['AETHER_PROJECT_ROOT'] = $project_root
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
# The Bonjour advertiser (`dns-sd -R`) is a child process; if the daemon dies on
# a signal before `shutdown` runs, the child would orphan and keep advertising a
# dead context. Kill it on every exit path so the æther never promises a ghost.
at_exit do
  begin
    Process.kill('TERM', $aether_bonjour_pid) if $aether_bonjour_pid
  rescue StandardError
    nil
  end
end

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
require_relative 'oracle/gist_bus'
require_relative 'instrumentarium/instrumenta'
require_relative 'instrumentarium/prima_materia'
require_relative 'instrumentarium/horologium_aeternum'
require_relative 'magnum_opus/magnum_opus_engine'
require_relative 'shell_session'
require_relative 'textmate_tokenizer'
require_relative 'instrumentarium/vox'

# PipeStream adapts HorologiumAeternum's WebSocket-style sink to STDOUT frames.
# HorologiumAeternum.send builds a JSON string {"method":...,"result":{...}}
# and calls @websocket.send(payload). We re-frame it as a typed stream event.
# The held thread (⏸). A user pause is *not* an interrupt: the Oracle stops at
# its next step boundary and waits — the worker thread, the live messages, the
# stream and the msg_uuid all stay alive, so ▶ continues this very chapter and a
# word woven in during the hold is already in `messages` when the next step
# departs. Distinct from `:paused`, which *unwinds* the turn so a context switch
# can rebase onto another project.
#
# One writer each: the worker waits, the control thread (⏸ / ▶ / ⏹ / weave)
# signals. Frames are never written while the gate lock is held, so the lock
# order (gate → frame) is consistent with every other emitter.
class TurnGate
  # While held the turn whispers into the stream now and then. Swift's watchdog
  # only declares a daemon wedged after a fully *silent* window, so a long hold
  # must keep breathing; the frame is otherwise ignored — it exists to prove life.
  HEARTBEAT_INTERVAL = 15.0

  def initialize(beat: nil)
    @mutex = Mutex.new
    @cv = ConditionVariable.new
    @held = false
    @aborted = false
    @messages = nil
    @pending = []
    @beat = beat
  end

  # The worker hands the gate the live conversation at every boundary. The loop
  # mutates that array in place (`messages.replace …`), so a later weave from the
  # control thread reaches the very next API call. A word woven in *before* the
  # first boundary (the turn was still assembling its context) is flushed here,
  # so a hold is never lost to the gap between ⏸ and the first step.
  def arm(messages)
    @mutex.synchronize do
      @messages = messages
      @pending.each { |text| messages << { role: 'user', content: text } }
      @pending.clear
    end
    self
  end

  def hold
    @mutex.synchronize do
      @held = true
      @aborted = false
    end
    self
  end

  def held?
    @mutex.synchronize { @held }
  end

  # Weave the user's word into the held chapter. Returns the new message count,
  # or nil when nothing is held. Before the first boundary the word waits in
  # `@pending` and lands with the next `arm`.
  def inject(text)
    @mutex.synchronize do
      return nil unless @held
      unless @messages
        @pending << text.to_s
        return 0
      end
      @messages << { role: 'user', content: text.to_s }
      @messages.size
    end
  end

  # ▶ — release the hold; the loop resumes with whatever has been woven in.
  def release
    @mutex.synchronize do
      was = @held
      @held = false
      @aborted = false
      @cv.broadcast
      was
    end
  end

  # ⏹ / context switch — tear the wait so the pending `:paused` unwind is actually
  # reached and the chapter ends.
  def abort!
    @mutex.synchronize do
      was = @held
      @held = false
      @aborted = true
      @cv.broadcast
      was
    end
  end

  # Blocks while held. Called from the Oracle loop at every step boundary; a
  # no-op (one mutex) when nobody held the turn.
  def wait
    @mutex.synchronize do
      return :released unless @held
      while @held
        @cv.wait(@mutex, HEARTBEAT_INTERVAL)
        @beat&.call if @held
      end
      @aborted ? :aborted : :released
    end
  end
end

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

# Captures the single `result` frame the worker emits for an HTTP-queued turn.
# The worker writes `emit(...)` to `Thread.current[:aether_sink]`; this sink is
# that sink — it parses the JSON frame and hands it to the waiting HTTP thread.
class HTTPResultSink
  def initialize(queue)
    @queue = queue
  end

  def write(data)
    frame = begin
      JSON.parse(data)
    rescue StandardError
      nil
    end
    @queue << frame if frame.is_a?(Hash) && frame['type'] == 'result'
  end

  def flush; end
end

# Minimal LAN HTTP server (stdlib only). WEBrick is not in the bundle's lock, so
# the æther opens its few JSON doors with a plain TCPServer — one listener, one
# thread per request, HTTP/1.1 with Content-Length and Connection: close.
class AetherHTTPServer
  STATUS_TEXT = {
    200 => 'OK', 400 => 'Bad Request', 404 => 'Not Found',
    405 => 'Method Not Allowed', 409 => 'Conflict',
    422 => 'Unprocessable Entity', 500 => 'Internal Server Error'
  }.freeze

  def initialize(port, handler)
    @port = port
    @handler = handler
    @server = TCPServer.new('0.0.0.0', port)
    @running = true
  end

  def start
    @thread = Thread.new do
      while @running
        begin
          client = @server.accept
          Thread.new(client) { |c| handle(c) }
        rescue IOError, Errno::EBADF
          break unless @running
        rescue StandardError => e
          warn "[AETHER-HTTP] accept: #{e.message}"
        end
      end
    end
  end

  def stop
    @running = false
    @server.close rescue nil
    @thread&.kill
  end

  private

  def handle(client)
    request_line = client.gets
    return client.close unless request_line
    method, path, = request_line.strip.split(' ')
    headers = {}
    while (line = client.gets)
      line = line.strip
      break if line.empty?
      key, value = line.split(':', 2)
      headers[key.downcase] = value.to_s.strip if key
    end
    body = ''
    if headers['content-length']
      body = client.read(headers['content-length'].to_i) || ''
    end
    status, payload = @handler.call(method, path, body)
    write_response(client, status, payload)
  rescue StandardError => e
    write_response(client, 500, { error: "#{e.class}: #{e.message}" }.to_json)
  ensure
    client.close rescue nil
  end

  def write_response(client, status, json_body)
    body = json_body.to_s
    client.write("HTTP/1.1 #{status} #{STATUS_TEXT[status] || 'OK'}\r\n" \
                 "Content-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n" \
                 "#{body}")
  rescue StandardError
    nil
  end
end

class StandaloneDaemon
  # A held turn (⏸) whispers into the stream now and then: Swift's watchdog only
  # declares a daemon wedged after a fully *silent* window, so a long hold must
  # keep breathing. Pythia ignores the frame — it exists to prove life.
  TURN_HEARTBEAT = -> { HorologiumAeternum.send_status('heartbeat', { held: true }) }

  # Commands that must stay responsive even while a heavy computation runs.
  # They execute on the main thread immediately; `interrupt` and
  # `activate_context` additionally set the worker's cooperative pause flag, and
  # `pause_turn`/`resume_turn`/`weave_turn` are the user's hand on the live turn.
  # Control commands answer inline on the reader thread, so they stay responsive
  # while the single worker runs a heavy oracle turn. Only lightweight ledger
  # writes belong here — `execute_task`/`evaluate_task` must stay queued (they
  # own the worker), but `create_task` is a plain Mnemosyne insert and must never
  # wait behind a running computation: the UI's confirm has to answer at once.
  CONTROL_COMMANDS = %w[
    ping activate_context interrupt pause_turn resume_turn weave_turn
    aegis history get_note remove_note usage
    list_tasks create_task remove_task recall user_response
    seal_create seal_list seal_status seal_delegate
    task_detail tokenize
    agenda intent intent_take intent_act intent_done intent_dismiss intent_promote
    memory_sources memory_list
    gist
  ].freeze

  # A long model call (extended thinking / reasoning) or a slow tool can block
  # the single worker for many minutes without producing a single byte. The
  # client's inactivity watchdog would then declare the daemon dead even though
  # it is merely waiting. So we breathe a lightweight `heartbeat` status every
  # HEARTBEAT_INTERVAL seconds while a request is in flight — the client resets
  # its watchdog on any frame, so silence now only ever means a dead process.
  HEARTBEAT_INTERVAL = 30

  def initialize
    @stream = PipeStream.new
    HorologiumAeternum.set_websocket(@stream)
    @engine = MagnumOpusEngine.new(mnemosyne: Mnemosyne, aetherflux: Aetherflux)
    @shell = ShellSession.new($project_root)
    # The agent's run_command instrument resolves its cwd through this handle,
    # coupling the user's CLI and the model's shell into one filesystem truth.
    $aether_shell = @shell
    @running = true
    # Thread-per-flow: every heavy turn (oracle/chat/companion/conjuration/task)
    # runs on its own thread so flows proceed independently. `@flow_threads`
    # tracks the live set for fan-out (pause/interrupt/shutdown); `@active_flows`
    # is the real busy signal; `@gates` maps flow_id → {gate, kind} so ⏸/▶/weave
    # can still reach the main conversation turn; `@shell_epoch` guards the trunk
    # shell against stale branch merges across a context switch.
    @flow_threads = []
    @flow_mutex = Mutex.new
    @active_flows = 0
    @gates = {}
    @shell_epoch = 0
    # The LAN æther: the HTTP port the iOS companion reaches.
    @http_port = nil
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
  # the skill's domain (trigger/grant/reach/tools), so the companion menu can
  # show each voice's abilities and permission without duplicating the skills.
  # One roster, two worlds — correspondence, not duplication.
  def companion_roster
    COMPANION_PERSONALITIES.map do |key, p|
      t = COMPANION_TEMPERAMENTS[key] || {}
      skill = (defined?(CompanionPrograms) && CompanionPrograms::COMPANION_SKILLS[key]) || {}
      {
        key: key.to_s,
        glyph: p[:glyph],
        name: p[:name],
        temperature: t[:temperature],
        thinking: t[:thinking],
        trigger: skill[:trigger].to_s,
        grant: skill[:grant].to_s,
        reach: skill[:reach].to_s,
        tools: Array(skill[:tools])
      }
    end
  end

  # Thread-per-flow executor: every heavy turn (oracle/chat/companion/conjuration/
  # task) runs on its own thread so flows proceed independently instead of
  # queueing behind one serial worker. No SQLite race (Mnemosyne serializes
  # behind DB_LOCK), no shell race (each flow branches its own ShellSession and
  # merges back under @flow_mutex, guarded by @shell_epoch so a context switch
  # never gets clobbered by a stale branch). The wire is already thread-local —
  # `emit` and PipeStream carry aether_sink/aether_request_id per thread and
  # FRAME_MUTEX serializes writes — so concurrent frames interleave without
  # tearing, and the Swift reader can demux them by request_id.
  def spawn_flow(request, request_id, sink)
    flow_id = request_id || "req_#{SecureRandom.hex(6)}"
    meta = flow_metadata(request)
    thread = Thread.new do
      Thread.current.report_on_exception = true
      run_flow(request, request_id, sink, flow_id, meta)
    ensure
      @flow_mutex.synchronize { @flow_threads.delete(Thread.current) }
    end
    @flow_mutex.synchronize { @flow_threads << thread }
    thread
  end

  # One flow's full lifecycle, on its own thread. A flow death is isolated — it
  # never takes the daemon down (unlike the old single worker, whose death made
  # queued turns hang forever).
  def run_flow(request, request_id, sink, flow_id, meta)
    answered = false
    Thread.current[:paused] = false
    Thread.current[:aether_request_id] = request_id
    Thread.current[:aether_sink] = sink
    # A fresh gate per turn: ⏸ holds *this* chapter, ▶ releases it, ⏹ tears it.
    gate = TurnGate.new(beat: TURN_HEARTBEAT)
    Thread.current[:pause_gate] = gate
    @flow_mutex.synchronize { @gates[flow_id] = { gate: gate, kind: meta[:kind] } }

    # Gist Bus: register this turn as a live flow so sibling flows see its
    # public silhouette (who + when + Aegis summary, never its reasoning or
    # tool bodies). The thread-local carries the flow's identity into the
    # conduit build so the turn can exclude itself and filter broadcasts.
    GistBus.begin_flow(id: flow_id, kind: meta[:kind], label: meta[:label],
                       companion: meta[:companion], project: $project_root)
    GistBus.set_aegis(flow_id, (Mnemosyne.aegis || {})[:summary].to_s)
    Thread.current[:aether_flow] = {
      id: flow_id, kind: meta[:kind], label: meta[:label],
      companion: meta[:companion], project: $project_root
    }

    heartbeat = nil
    turn_shell = nil
    epoch = nil
    incr = false
    begin
      turn_shell, epoch = @flow_mutex.synchronize { [@shell.branch, @shell_epoch] }
      Thread.current[:aether_shell] = turn_shell
      @flow_mutex.synchronize { @active_flows += 1 }
      incr = true
      heartbeat = start_heartbeat
      result = dispatch(request['command'], request['arguments'] || {})
      answered = true
      emit(type: 'result', request_id: request_id, success: true, result: result)
    rescue Exception => e
      # Purificatio: StandardError misses SyntaxError/LoadError/NoMemoryError
      # & co. — a SyntaxError from eval'd tooling would otherwise kill the
      # flow silently (no result, no recover) and hang Swift until its lease.
      # Fatal shutdown signals still propagate so the daemon can exit.
      raise if e.is_a?(SystemExit) || e.is_a?(SignalException)

      answered = true
      emit(type: 'result', request_id: request_id, success: false,
           error: "#{e.class}: #{e.message}")
      # Riss §7: when a turn breaks (lease expiry / error), the companion
      # becomes the next chapter's beginning — surface a one-click recovery
      # macro instead of a dead end. The last intention lives in Aegis.
      begin
        last_intent = (Mnemosyne.aegis || {})[:summary].to_s
        # The riss becomes an intention in Pythia's agenda (aspect: phoenix,
        # the facet that rises from failure) — recovery is not a dead end but
        # the next chapter already signed into the manifest.
        intent = begin
          Mnemosyne::AethernautManifest.enqueue(
            kind: :recovery, aspect: :phoenix, source: 'riss',
            title: 'Hier riss der Faden — weiterweben?',
            body: last_intent[0, 400], action: 'recover_last_intent'
          )
        rescue Exception
          nil
        end
        emit(type: 'recover_suggestion',
             request_id: request_id,
             glyph: '🦊',
             prompt: 'Hier riss der Faden — weiterweben?',
             action: 'recover_last_intent',
             intent_id: intent && intent[:id],
             last_intent: last_intent[0, 400])
      rescue Exception
        nil
      end
    ensure
      @flow_mutex.synchronize { @active_flows -= 1 } if incr
      heartbeat&.kill
      # Merge the turn's branch back into the trunk unless a context switch
      # replaced it mid-flight (activate_context resets @shell and bumps the
      # epoch; a stale branch from the old project must not clobber the new cwd).
      if turn_shell
        @flow_mutex.synchronize { @shell.merge_from(turn_shell) if @shell_epoch == epoch }
      end
      Thread.current[:aether_shell] = nil
      GistBus.end_flow(flow_id)
      Thread.current[:aether_flow] = nil
      Thread.current[:paused] = false
      Thread.current[:pause_gate] = nil
      @flow_mutex.synchronize { @gates.delete(flow_id) }
      Thread.current[:aether_request_id] = nil
    end
  rescue Exception => e
    # Setup failure (before the begin above): still answer so Swift never hangs.
    unless answered
      begin
        emit(type: 'result', request_id: request_id, success: false,
             error: "#{e.class}: #{e.message}")
      rescue StandardError
        nil
      end
    end
    warn "[AETHER-DAEMON] flow #{flow_id} died: #{e.class}: #{e.message}"
    warn(e.backtrace.join("\n")) if e.backtrace
  end

  # Whether any heavy flow is in flight — the busy gate for the LAN æther and
  # the heartbeat payload.
  def busy?
    @flow_mutex.synchronize { @active_flows } > 0
  end

  def active_flow_count
    @flow_mutex.synchronize { @active_flows }
  end

  # Transport dispatch: `--listen SOCKET` runs the ÆtherLimen background service
  # (Unix-domain socket, survives the app); otherwise the daemon speaks the
  # original framed JSON protocol over STDIN/STDOUT (dev / spawn mode).
  def run
    # The LAN æther (HTTP + Bonjour) rides along in every mode: the iOS
    # companion reaches this very brain over http://<mac>:<port>/aether/...
    start_http_server
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
      spawn_flow(request, request_id, sink)
    end
  end

  # ── The LAN æther: HTTP + Bonjour for the iOS companion ──
  # One brain, many windows. The Ruby brain already speaks a framed JSON
  # protocol over STDIN/STDOUT (and a Unix socket); here it also opens an HTTP
  # door on the LAN (0.0.0.0) and advertises itself via Bonjour so the iOS
  # companion can find it without ever typing an IP address.

  def start_http_server
    port = (ENV['AETHER_PORT'] && ENV['AETHER_PORT'].to_i)
    port = CONFIG.port.to_i if port.nil? || port <= 0
    port = 4567 if port.nil? || port <= 0
    @http_port = port

    @http_server = AetherHTTPServer.new(port, method(:http_route))
    @http_server.start
    warn "[AETHER-HTTP] listening on 0.0.0.0:#{port}"
    start_bonjour(port)
  rescue StandardError => e
    warn "[AETHER-HTTP] failed to start: #{e.class}: #{e.message}"
  end

  # Route one HTTP request to a [status, json_string] pair.
  def http_route(method, path, body)
    case [method, path]
    when ['GET', '/aether/heartbeat']
      [200, heartbeat_payload.to_json]
    when ['POST', '/aether/invoke']
      http_invoke(body)
    when ['GET', '/aether/voices']
      [200, { voices: Vox.voices }.to_json]
    when ['POST', '/aether/speak']
      http_speak(body)
    when ['GET', '/aether/pending']
      [200, { questions: HorologiumAeternum.pending_questions }.to_json]
    when ['POST', '/aether/respond']
      http_respond(body)
    when ['GET', '/aether/aegis']
      aegis = Mnemosyne.aegis || {}
      [200, {
        thinking: aegis[:thinking] || 'normal',
        temperature: aegis[:temperature] || 1.0,
        working_dir: aegis[:working_dir],
        summary: aegis[:summary] || '',
        tags: aegis[:tags] || []
      }.to_json]
    else
      [404, { error: 'Not found' }.to_json]
    end
  end

  def http_invoke(body)
    payload = begin
      JSON.parse(body.to_s, symbolize_names: true)
    rescue StandardError
      {}
    end
    prompt = payload[:prompt].to_s.strip
    memory = Array(payload[:memory]).reject(&:nil?)
    active = payload[:active_companions].is_a?(Array) ? payload[:active_companions] : nil

    if prompt.empty? && memory.empty?
      return [400, { error: 'Missing prompt' }.to_json]
    end
    if busy?
      return [409, { error: 'busy', message: 'The oracle is mid-turn.', busy: true }.to_json]
    end

    frame = http_oracle_turn(prompt: prompt, active_companions: active, memory: memory)
    if frame['success'] == false
      return [500, { error: frame['error'].to_s }.to_json]
    end
    result = frame['result'] || {}
    resp = result['response']
    if resp.is_a?(Hash)
      [200, { answer: resp['answer'].to_s, html: resp['html'],
              source_context: 'pythia-ios' }.to_json]
    elsif resp.is_a?(String)
      [500, { error: resp }.to_json]
    else
      [200, { answer: '', html: nil, source_context: 'pythia-ios' }.to_json]
    end
  end

  def http_speak(body)
    payload = begin
      JSON.parse(body.to_s, symbolize_names: true)
    rescue StandardError
      {}
    end
    text = payload[:text]
    if !text.is_a?(String) || text.strip.empty?
      [422, { error: 'text is required' }.to_json]
    else
      [200, { ok: Vox.speak(text: text, voice: payload[:voice]) }.to_json]
    end
  end

  # Answer a pending `ask_user` consultation raised mid-turn. The turn is paused
  # inside `await_user_response`; pushing the response unblocks it immediately.
  def http_respond(body)
    payload = begin
      JSON.parse(body.to_s, symbolize_names: true)
    rescue StandardError
      {}
    end
    uuid = payload[:uuid].to_s
    response = payload[:response].to_s
    if uuid.empty? || response.empty?
      [422, { error: 'uuid and response are required' }.to_json]
    else
      HorologiumAeternum.receive_user_response(uuid, response)
      [200, { ok: true }.to_json]
    end
  end

  # Advertise the Mac on the local network via Bonjour (`dns-sd`), so the iOS
  # companion browses `_aethercodex._tcp` and finds us without an IP address.
  def start_bonjour(port)
    $aether_bonjour_pid = Process.spawn(
      'dns-sd', '-R', 'AetherCodex', '_aethercodex._tcp', 'local', port.to_s,
      'name=AetherCodex', out: File::NULL, err: File::NULL
    )
    warn "[AETHER-HTTP] Bonjour advertising _aethercodex._tcp : #{port}"
  rescue StandardError => e
    warn "[AETHER-HTTP] Bonjour failed: #{e.message}"
  end

  def stop_bonjour
    return unless $aether_bonjour_pid
    Process.kill('TERM', $aether_bonjour_pid) rescue nil
    $aether_bonjour_pid = nil
  end

  def heartbeat_payload
    active_tasks = begin
      Mnemosyne.manage_tasks(action: 'list')
               .select { |t| t[:status] == 'active' }
    rescue StandardError
      []
    end
    {
      name: 'AetherCodex',
      path: $project_root,
      port: @http_port,
      capabilities: %w[metempsychosis task_spawn invoke manifest],
      version: '3.0.0',
      busy: busy?,
      active_tasks: active_tasks
    }
  end

  # Queue an oracle turn through the single worker (serialized, linear history)
  # and wait for its result frame. The iOS companion sends `active_companions`
  # (array); map the first non-Pythia voice to `companion` so that companion
  # actually answers instead of default Pythia.
  def http_oracle_turn(prompt:, active_companions: nil, memory: [])
    queue = Queue.new
    sink = HTTPResultSink.new(queue)

    messages = memory
    if messages.empty? && !prompt.empty?
      messages = [{ 'role' => 'user', 'content' => prompt }]
    end

    # Broadcast the iOS prompt into the Mac panel's live stream so the companion's
    # words appear in *both* windows. Without this the panel only saw the tool
    # telemetry that followed — the prompt itself stayed invisible there.
    unless prompt.empty?
      HorologiumAeternum.send_status('user_message', { role: 'user', content: prompt })
    end

    args = { 'messages' => messages, 'history' => false, 'record' => false }
    if active_companions.is_a?(Array) && !active_companions.empty?
      voice = active_companions.first.to_s
      args['companion'] = voice unless voice.empty? || voice == 'pythia'
    end

    spawn_flow({ 'command' => 'oracle', 'arguments' => args },
               "http_#{SecureRandom.hex(6)}", sink)
    queue.pop || {}
  end

  def shutdown
    stop_bonjour
    @http_server&.stop
    warn "[AETHER-DAEMON] shutdown (pid #{Process.pid})"
    @running = false
    threads = @flow_mutex.synchronize { @flow_threads.dup }
    threads.each { |t| t.join(2) }
  end

  # Snapshot of the oracle's breath: which model/thinking level is active, the
  # current session's token + cost ledger, and the all-time totals. Pure reads —
  # safe on the control path, so the status bar can poll it mid-computation.
  def usage_snapshot
    session = TokenLedger.session
    persisted = TokenLedger.persisted
    thinking = Mnemosyne.aegis[:thinking].to_s
    thinking = 'normal' if thinking.empty?
    {
      model: CONFIG.model.to_s,
      fast_model: CONFIG.fast_model.to_s,
      api_type: CONFIG.api_type.to_s,
      thinking: thinking,
      project_root: $project_root.to_s,
      session: {
        prompt_tokens: session[:prompt_tokens].to_i,
        completion_tokens: session[:completion_tokens].to_i,
        cost: session[:cost].to_f,
        turns: session[:turns].to_i
      },
      persisted: {
        prompt_tokens: persisted[:prompt_tokens].to_i,
        completion_tokens: persisted[:completion_tokens].to_i,
        cost: persisted[:cost].to_f,
        sessions: persisted[:sessions].to_i
      }
    }
  end

  def dispatch(command, args)
    case command
    when 'ping'
      { pong: true, time: Time.now.to_f, cwd: ($aether_shell || @shell).cwd }

    # -- Hermetic accounting (context + token ledger + cost) --
    when 'usage', 'ledger'
      usage_snapshot

    # -- Mnemosyne --
    when 'remember'
      Mnemosyne.remember(content: args['content'], links: args['links'], tags: args['tags'])
    when 'recall'
      Mnemosyne.recall_notes(args['query'].to_s, limit: args.fetch('limit', 5))
    when 'memory_sources'
      Mnemosyne::Import.sources
    when 'memory_list'
      Mnemosyne::Import.list(path: args['path'], query: args['query'], tag: args['tag'], limit: args.fetch('limit', 50))
    when 'memory_import'
      Mnemosyne::Import.import(
        path: args['path'],
        ids: args.fetch('ids', []),
        query: args['query'],
        tag: args['tag'],
        include_companions: args.fetch('include_companions', true),
        label: args['label']
      )
    when 'get_note'
      Mnemosyne.get_note(args['id'])
    when 'remove_note'
      Mnemosyne.remove_note(args['id'])
    when 'history'
      Mnemosyne.fetch_history(limit: args.fetch('limit', 7), include_tool_calls: args.fetch('include_tool_calls', false))

    # -- Aegis --
    when 'aegis'
      handle_aegis(args)

    # -- Gist Bus (flow-event bus: broadcasts + running flows) --
    when 'gist'
      handle_gist(args)

    # -- AethernautManifest (Pythia's agenda) --
    when 'agenda'
      Mnemosyne::AethernautManifest.agenda(status: args['status'], limit: args['limit'])
    when 'intent'
      Mnemosyne::AethernautManifest.enqueue(
        kind: args.fetch('kind', 'suggestion'),
        title: args.fetch('title'),
        aspect: args['aspect'], glyph: args['glyph'], body: args['body'],
        action: args['action'], payload: args['payload'] || {},
        priority: args.fetch('priority', 0), source: args['source']
      )
    when 'intent_take'
      Mnemosyne::AethernautManifest.take
    when 'intent_act'
      intention = args['intention'] || Mnemosyne::AethernautManifest.find(args.fetch('id'))
      Mnemosyne::AethernautManifest.act(intention)
    when 'intent_done'
      Mnemosyne::AethernautManifest.complete(args.fetch('id'))
    when 'intent_dismiss'
      Mnemosyne::AethernautManifest.dismiss(args.fetch('id'), reason: args['reason'])
    when 'intent_promote'
      Mnemosyne::AethernautManifest.promote(args.fetch('id'), args.fetch('priority'))

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
    when 'continue_task'
      spawn_task_runner(args.fetch('id'), restart: args['restart'] ? true : false)
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

    # -- TextMate grammar tokenizer (breadth syntax highlighting) --
    when 'tokenize'
      handle_tokenize(args)

    # -- Pythia CLI (polymorphic shell shared with the agent's run_command) --
    when 'cli'
      handle_cli(args)

    # -- Polymorphic context switch --
    when 'activate_context'
      activate_context(args['path'].to_s)

    # -- ⏸ / ▶ / weave — the user's hand on the running turn --
    when 'pause_turn'
      hold_turn
    when 'resume_turn'
      release_turn
    when 'weave_turn'
      weave_turn(args['text'])

    # -- Project config introspection / write (the native editor's config view) --
    when 'config'
      handle_config(args)

    when 'set_config'
      handle_set_config(args)

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

  # Launch a Magnum Opus task on its own thread and answer immediately, so the
  # UI can run several tasks concurrently. Each runner drives the shared engine;
  # SQLite I/O is serialized behind Mnemosyne's DB_LOCK while the oracle turns
  # (the slow part) overlap. Telemetry flows through HorologiumAeternum's
  # PipeStream, which is mutex-guarded and thread-safe.
  def spawn_task_runner(task_id, restart: false)
    thread = Thread.new do
      Thread.current.report_on_exception = true
      turn_shell = nil
      epoch = nil
      begin
        turn_shell, epoch = @flow_mutex.synchronize { [@shell.branch, @shell_epoch] }
        Thread.current[:aether_shell] = turn_shell
        @engine.continue_task(task_id, restart: restart)
      rescue StandardError => e
        warn "[AETHER-DAEMON] task runner #{task_id} died: #{e.class}: #{e.message}"
        warn(e.backtrace.join("\n")) if e.backtrace
      ensure
        if turn_shell
          @flow_mutex.synchronize { @shell.merge_from(turn_shell) if @shell_epoch == epoch }
        end
        Thread.current[:aether_shell] = nil
      end
    ensure
      @flow_mutex.synchronize { @flow_threads.delete(Thread.current) }
    end
    @flow_mutex.synchronize { @flow_threads << thread }
    { ok: true, id: task_id, started: true, restart: restart }
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
    @flow_mutex.synchronize do
      @shell&.reset($project_root)
      @shell_epoch += 1
    end
    # Re-point the active shell handle: any in-flight turn branch is stale now,
    # so the trunk and the instrument's handle both breathe the new project.
    $aether_shell = @shell

    {
      project_root: $project_root,
      name: CONFIG.project_name,
      config_path: CONFIG.config_file_in($project_root),
      memory_db: CONFIG.memory_db_path
    }
  end

  # Effective project config (values + source layers) for the native editor.
  def handle_config(_args)
    CONFIG.effective_config($project_root)
  end

  # Write one config key into the project's `.aethercodex` / `.aether_properties`,
  # or into `~/.aethercodex` when `target` is 'home' (the personal defaults).
  def handle_set_config(args)
    key = args['key'].to_s
    return { error: 'set_config: no key given' } if key.empty?
    CONFIG.write_key(key, args['value'], args['target'].to_s)
  end

  # Set the worker's cooperative pause flag. The Oracle loop checks
  # Thread.current[:paused] at each boundary and returns a divine interrupt.
  def pause_worker
    threads = @flow_mutex.synchronize { @flow_threads.dup.select(&:alive?) }
    threads.each { |t| t[:paused] = true }
  end

  # Spawns a daemon-thread heartbeat: every HEARTBEAT_INTERVAL seconds it emits a
  # `heartbeat` status frame so a long model/tool turn never looks like a dead
  # daemon to the client's inactivity watchdog. The worker kills it in `ensure`
  # the moment the request finishes.
  def start_heartbeat
    # Capture the worker's frame context before spawning: the heartbeat thread
    # won't inherit Thread.current locals, so carry request_id + sink explicitly.
    request_id = Thread.current[:aether_request_id]
    sink = Thread.current[:aether_sink]
    Thread.new do
      Thread.current[:aether_request_id] = request_id
      Thread.current[:aether_sink] = sink
      loop do
        sleep HEARTBEAT_INTERVAL
        begin
          emit(type: 'stream', method: 'status', payload: {
                 type: 'heartbeat',
                 data: { message: 'the oracle is still channeling…' },
                 timestamp: Time.now.to_f,
                 uuid: nil
               })
        rescue StandardError => e
          warn "[AETHER-DAEMON] heartbeat failed: #{e.message}"
        end
      end
    end
  end

  # Walk up from `path` (file or directory) to the nearest config file
  # (`.aethercodex` or `.aether_properties`); if none exists, the opened
  # directory becomes the project root. Delegates to CONFIG so context identity
  # stays identical to the rest of the brain.
  def resolve_project_root(path)
    path = File.expand_path(path)
    return nil unless File.exist?(path)
    CONFIG.find_project_root(path)
  end

  # Best-effort cancellation of the running Oracle request. Aetherflux tracks the
  # active HorologiumAeternum token; signalling it lets the model stop cleanly
  # without killing the daemon, so the queued interjection can run next.
  def interrupt_computation
    threads = @flow_mutex.synchronize { @flow_threads.dup.select(&:alive?) }
    if threads.empty?
      { interrupted: false, note: 'no in-flight computation' }
    else
      threads.each { |t| t[:paused] = true }
      { interrupted: true, active_flows: threads.size }
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

  # Tokenize `text` with a TextMate grammar. Accepts a full `grammar_path` so the
  # Swift side owns resource resolution (dev vs. bundled-app layout differ). This
  # runs on the control path — textpow is fast and must never queue behind a
  # heavy agentic turn.
  def handle_tokenize(args)
    path = args['grammar_path'].to_s
    text = args['text'].to_s
    return { error: 'tokenize: no grammar_path' } if path.empty?
    return { error: "tokenize: grammar not found: #{path}" } unless File.file?(path)

    TextmateTokenizer.tokenize(path, text)
  end

  def handle_aegis(args)
    case args['action']
    when 'get'
      Mnemosyne.restore_aegis
      state = Mnemosyne.aegis.dup
      tags = state[:tags]
      state[:tags] = tags.is_a?(String) ? tags.split(',').map(&:strip) : Array(tags)
      state[:notes] = Mnemosyne.recall_aegis_notes(limit: recall_depth(args))
      state
    when 'notes'
      Mnemosyne.recall_aegis_notes(max_tokens: args['max_tokens'],
                                   max_content_length: args['max_content_length'],
                                   limit: recall_depth(args))
    when 'agenda'
      Mnemosyne::AethernautManifest.agenda(status: args['status'], limit: args['limit'])
    when 'update', 'unveil'
      opts = {}
      opts[:summary] = args['summary'] if args.key?('summary')
      opts[:tags] = args['tags'] if args.key?('tags')
      opts[:temperature] = args['temperature'] if args.key?('temperature')
      opts[:thinking] = args['thinking'] if args.key?('thinking')
      opts[:working_dir] = args['working_dir'] if args.key?('working_dir')
      Mnemosyne.unveil_aegis(**opts)
      { ok: true, aegis: Mnemosyne.aegis }
    else
      { error: "Unknown aegis action: #{args['action']}" }
    end
  end

  # The assembler's one exposed knob — how many notes the orientation carries.
  # Defaults to the historical depth of 8; bounded so a stray value can never
  # flood the context.
  def recall_depth(args)
    depth = args['limit'].to_i
    depth.zero? ? 8 : depth.clamp(1, 40)
  end

  # The Gist Bus control surface: broadcast a message into every relevant flow's
  # conduit (or one companion's), and read the live flow society. Runs inline
  # (control command) so a broadcast reaches queued flows even mid-computation.
  def handle_gist(args)
    case args['action']
    when 'broadcast', 'announce'
      content = args['content'].to_s
      return { error: 'gist broadcast: no content' } if content.strip.empty?

      entry = GistBus.broadcast(content: content, author: args.fetch('author', 'user'),
                                target: args['target'])
      { ok: true, broadcast: entry }
    when 'running', 'flows'
      GistBus.running.map { |f| gist_flow_view(f) }
    when 'broadcasts'
      GistBus.broadcasts.map do |m|
        { id: m[:id], at: m[:at], author: m[:author], target: m[:target], content: m[:content] }
      end
    else
      { error: "Unknown gist action: #{args['action']}" }
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

    reply = Aetherflux.channel_oracle_divination(params, tools: Instrumenta, context: context)
    normalize_held_reply(reply)
  end

  # A held (⏸) or torn (⏹ / context switch) turn returns the Oracle's divine
  # interrupt signal instead of an answer. Normalize it into the one reply shape
  # every other turn uses, flagged `held: true`, so Swift closes the chapter
  # without rendering a phantom answer.
  def normalize_held_reply(reply)
    return reply unless reply.is_a?(Array)
    signal = reply.first
    return reply unless signal.is_a?(Hash) && signal[:__divine_interrupt]

    {
      status: :success,
      response: {
        answer: '', html: '', held: true,
        reason: signal[:__reason].to_s,
        companion_suggestions: [], logs: [], tool_results: [],
        execution_time: 0, tool_call_count: 0
      }
    }
  end

  # ⏸ — hold the in-flight turn at its next step boundary. Not an interrupt: the
  # turn keeps its thread, its messages and its stream, so ▶ continues the very
  # same chapter and a woven word reaches the next step.
  def hold_turn
    gate = current_gate
    return { held: false, note: 'no in-flight computation' } unless gate

    gate.hold
    { held: true, active_flows: active_flow_count }
  end

  # ▶ — release a held turn; the loop resumes with whatever has been woven in.
  def release_turn
    gate = current_gate
    return { released: false, held: false, note: 'no in-flight computation' } unless gate

    { released: gate.release, held: gate.held? }
  end

  # ⏸ + a word: weave the user's addition into the held chapter *before* the next
  # step and let it continue — the user's hand reaches the running turn instead of
  # queueing behind it. No held thread (it closed first) → woven false, and the
  # caller opens its own chapter with the word.
  def weave_turn(text)
    return { error: 'weave_turn: empty text' } if text.to_s.strip.empty?

    gate = current_gate
    return { woven: false, note: 'no held turn' } unless gate&.held?

    woven = gate.inject(text)
    gate.release
    { woven: !woven.nil?, messages: woven, active_flows: active_flow_count }
  end

  # The gate of the main conversation turn (nil between turns). Companion and
  # task flows run independently beside it; ⏸/▶/weave are the user's hand on the
  # primary oracle chapter, so we target the most recently started oracle gate.
  def current_gate
    mains = @flow_mutex.synchronize do
      @gates.values.select { |g| g[:kind] == :oracle }
    end
    mains.last && mains.last[:gate]
  end

  private

  # The public silhouette of a live flow for the Swift side — never its tool
  # bodies or reasoning, only who/when/what (the Aegis summary).
  def gist_flow_view(flow)
    { id: flow[:id], kind: flow[:kind], label: flow[:label], companion: flow[:companion],
      started_at: flow[:started_at].iso8601, aegis: flow[:aegis] }
  end

  # Classify a queued request into a Gist Bus flow label + companion key, so
  # sibling flows see *who* is running without guessing. Companion turns carry
  # their own key (for broadcast filtering); everything else is the main agent.
  def flow_metadata(request)
    args = request['arguments'] || {}
    case request['command']
    when 'companion'
      key = (args['name'] || args['companion']).to_s
      { kind: :companion, label: companion_display(key), companion: key }
    when 'oracle', 'chat', 'conjuration'
      key = (args['companion'] || args['name']).to_s
      if key && !key.empty?
        { kind: :companion, label: companion_display(key), companion: key }
      elsif args['active_companions'].to_a.any?
        { kind: :oracle, label: 'Pythia (conclave)', companion: nil }
      else
        hydra = args['hydra'].to_s
        label = hydra.empty? ? 'Pythia' : "Pythia·#{hydra}"
        { kind: :oracle, label: label, companion: nil }
      end
    when 'execute_task', 'continue_task', 'evaluate_task', 'seal_run'
      { kind: :task, label: 'Magnum Opus', companion: nil }
    else
      { kind: :oracle, label: 'Pythia', companion: nil }
    end
  end

  def companion_display(key)
    return 'Pythia' if key.to_s.strip.empty?
    defined?(CompanionPrograms) ? CompanionPrograms.display_name(key) : key.to_s
  end

  def symbolize_keys(hash)
    hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
  end
end

StandaloneDaemon.new.run