# frozen_string_literal: true

require 'net/http'
require 'json'

module AetherOracle
  # The LINK tier — pure Ruby stdlib, no gems. Discovers oracle peers on the LAN
  # and routes turns over the limen.rb wire contract (scan 4550..4610,
  # GET /aether/heartbeat, POST /aether/invoke). This is the aetherlink surface:
  # a Windows/Linux box reaches the brain on a Mac over the same wire, with only
  # Ruby installed — the aether is everywhere, and the voice finds it.
  module Link
    SCAN_RANGE = (4550..4610).freeze
    HEARTBEAT_PATH = '/aether/heartbeat'.freeze
    INVOKE_PATH = '/aether/invoke'.freeze
    MANIFEST_PATH = '/aether/manifest'.freeze
    CONNECT_TIMEOUT = 2
    READ_TIMEOUT = 180

    module_function

    def http_get(port, path, timeout: CONNECT_TIMEOUT)
      uri = URI("http://127.0.0.1:#{port}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = timeout
      http.read_timeout = READ_TIMEOUT
      res = http.get(uri.path)
      return nil unless res.code.to_i == 200

      JSON.parse(res.body, symbolize_names: true)
    rescue StandardError
      nil
    end

    def heartbeat(port)
      http_get(port, HEARTBEAT_PATH)
    end

    def peers
      SCAN_RANGE.filter_map do |port|
        info = heartbeat(port)
        name = info && (info[:name] || info['name'])
        next unless name

        {
          port: port,
          name: name,
          busy: info[:busy] || info['busy'] || false,
          version: info[:version] || info['version'],
          path: info[:path] || info['path'],
          capabilities: info[:capabilities] || info['capabilities'] || [],
          agenda_count: info[:agenda_count] || info['agenda_count'] || 0
        }
      end
    end

    def find_peer(peer)
      list = peers
      list.find { |p| p[:name] == peer } ||
        list.find { |p| p[:name].downcase == peer.downcase } ||
        begin
          port = Integer(peer, exception: false)
          port && port.between?(SCAN_RANGE.begin, SCAN_RANGE.end) ? { port: port, name: nil } : nil
        end
    end

    def print_peers
      list = peers
      if list.empty?
        warn 'No oracle peers found on the LAN (scanned 4550..4610).'
        warn 'Start a brain with: aetheroracle server'
        exit 1
      end

      puts format('%-6s %-32s %-6s %-8s %-6s', 'PORT', 'NAME', 'BUSY', 'VERSION', 'AGENDA')
      puts '-' * 64
      list.each do |p|
        puts format('%-6d %-32s %-6s %-8s %-6d', p[:port], p[:name], p[:busy] ? 'yes' : 'no', p[:version] || '?', p[:agenda_count].to_i)
      end
    end

    def probe_heartbeat(args)
      port = (args.first || 4567).to_i
      info = heartbeat(port)
      if info.nil?
        warn "No heartbeat on 127.0.0.1:#{port}"
        exit 1
      end
      puts JSON.pretty_generate(info)
    end

    def invoke_peer(args)
      if args.empty?
        warn 'Usage: aetheroracle invoke <peer> "prompt"'
        exit 1
      end

      peer = args.shift
      prompt = args.join(' ').strip
      prompt = $stdin.read.strip if prompt.empty? && !$stdin.tty?

      if prompt.empty?
        warn 'No prompt given. Usage: aetheroracle invoke <peer> "prompt"'
        warn '  or: echo "prompt" | aetheroracle invoke <peer>'
        exit 1
      end

      target = find_peer(peer)
      if target.nil?
        warn "No peer found: #{peer}"
        exit 1
      end

      uri = URI("http://127.0.0.1:#{target[:port]}#{INVOKE_PATH}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = { prompt: prompt, type: 'chat', from_context: 'aetheroracle-cli' }.to_json

      res = http.request(req)
      unless res.code.to_i == 200
        warn "invoke failed: HTTP #{res.code}"
        exit 1
      end

      body = JSON.parse(res.body, symbolize_names: true)
      if body[:error]
        warn "oracle error: #{body[:error]}"
        exit 1
      elsif body[:busy]
        warn 'oracle busy'
        exit 1
      end

      puts(body[:answer] || body['answer'] || body[:html] || body['html'])
    rescue StandardError => e
      warn "invoke failed: #{e.message}"
      exit 1
    end

    # Hoist a peer's freshly-updated manifest (the Aegis agenda) — the sails.
    def fetch_manifest(args)
      peer = args.first
      if peer.nil?
        warn 'Usage: aetheroracle manifest <peer>'
        exit 1
      end
      target = find_peer(peer)
      if target.nil?
        warn "No peer found: #{peer}"
        exit 1
      end
      info = http_get(target[:port], MANIFEST_PATH)
      if info.nil?
        warn "No manifest on #{peer}"
        exit 1
      end
      items = info[:manifest] || info['manifest'] || []
      puts "🧭 #{info[:name] || peer} — Pythia's Agenda (#{items.size} intentions, #{info[:pending]} pending)"
      puts '────────────────────────────────────────────'
      if items.empty?
        puts '(the manifest is empty — the course is clear)'
      else
        items.each do |i|
          status = i[:status] == 'active' ? '▶' : '•'
          puts "#{status} #{i[:glyph]} ##{i[:id]} [#{i[:kind]}] #{i[:title]}  (aspect: #{i[:aspect]}, prio: #{i[:priority]})"
        end
      end
    end

    # Sign an intention into a peer's manifest — inscribe a new sailor.
    def sign_manifest(args)
      if args.empty?
        warn 'Usage: aetheroracle sign <peer> <kind> "intention"'
        exit 1
      end
      peer = args.shift
      kind = args.shift || 'suggestion'
      title = args.join(' ').strip
      if title.empty?
        warn 'No intention given. Usage: aetheroracle sign <peer> <kind> "intention"'
        exit 1
      end
      target = find_peer(peer)
      if target.nil?
        warn "No peer found: #{peer}"
        exit 1
      end
      uri = URI("http://127.0.0.1:#{target[:port]}#{MANIFEST_PATH}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = { kind: kind, title: title, from_context: 'aetheroracle-cli' }.to_json
      res = http.request(req)
      unless res.code.to_i == 200
        warn "sign failed: HTTP #{res.code}"
        exit 1
      end
      body = JSON.parse(res.body, symbolize_names: true)
      if body[:ok]
        i = body[:intention] || {}
        puts "Signed ##{i[:id]} [#{i[:kind]}] #{i[:glyph]} into #{target[:name] || peer}'s agenda"
      else
        warn "sign failed: #{body[:error]}"
        exit 1
      end
    rescue StandardError => e
      warn "sign failed: #{e.message}"
      exit 1
    end

    def run(argv)
      command = argv.shift
      case command
      when 'peers', 'discover', 'ls'
        print_peers
      when 'heartbeat', 'hb'
        probe_heartbeat(argv)
      when 'invoke', 'ask-peer', 'link'
        invoke_peer(argv)
      when 'manifest', 'pull'
        fetch_manifest(argv)
      when 'sign', 'push'
        sign_manifest(argv)
      when 'help', '-h', '--help', nil
        print_help
      else
        warn "unknown command: #{command}"
        warn ''
        print_help
        exit 1
      end
    end

    def print_help
      puts <<~HELP
        AetherOracle — one oracle, many voices.

        The oracle has many names — all the same aether in the CLI:
          aetheroracle · aether · oracle · oracleaether · ae · aero · orae

        Usage: aetheroracle [command] [options]

        With no command, aetheroracle enters the Dialog-Kammer — the hermetic,
        polymorphic conversation room: an interactive REPL with twelve companion
        voices, slash-commands, live tool telemetry, and syntax-highlighted
        terminal Markdown.

        BRAIN tier (needs the brain gems — `gem install aetheroracle`):
          (no args)                  enter the Dialog-Kammer
          chamber [--theme NAME]     enter the Dialog-Kammer explicitly
          ask "prompt"               one-shot local oracle turn
          server                     start the daemon (limen.rb)
          config                     show configuration
          context                    show / create / switch the active context
          task <action>              task ledger (list / show <id> / create <title>)
          agenda                     show the local Aethernaut's Manifest (Pythia's agenda)
          intent add|take|done       act on the local manifest
          veil                       check, configure, and repair Aether setup
          logs                       tail the tagged log stream

        DEVELOPER TOOLBELT (mirrors the oracle's own instruments):
          read <path> [a:b]          read a file (line range, --numbers)
          inspect <path>             symbolic structural overview
          write <path> [--body …]    create/overwrite a file (or pipe)
          mv <from> <to>             rename/move a file
          files [glob]               list project files
          ast <pattern> [glob]       AST-GREP search
          notes [query]              recall Mnemosyne notes by fuzzy query
          note add|show|edit|rm      manage a Mnemosyne note
          history [n] [--notes]      recent chronicle history (or notes)
          search <query> [--limit n] search notes + chronicle
          aegis [show|summary|tags|temp|think|dir]  view/edit Aegis state
          seal list|status|delegate  Salomo's executive seals

        LINK tier (any platform with Ruby — no gems):
          peers                      discover oracle peers on the LAN (4550..4610)
          heartbeat [port]           probe one peer's heartbeat (default 4567)
          invoke <peer> "prompt"     route a turn to a remote oracle

        Install on any OS with Ruby:
          gem build aetheroracle.gemspec && gem install ./aetheroracle-*.gem
        Windows one-shot:
          powershell -ExecutionPolicy Bypass -File bin\\aetheroracle-setup.ps1

        Examples:
          aetheroracle                        # enter the Dialog-Kammer
          aetheroracle chamber --theme github # chamber with a light theme
          aetheroracle ask "refactor app.rb"
          oracle peers
          echo "what is the aether?" | ae invoke mac-oracle

        The link tier speaks the ruby/aether_link.rb contract — a Windows/Linux
        box reaches the brain on a Mac over the same wire. The aether is everywhere.
      HELP
    end
  end
end