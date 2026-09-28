# frozen_string_literal: true

require_relative 'log_tags'

# ── AetherLog::Viewer — the colorful, tagged, toggleable log tail. ─────────
# Reads the daemon's `limen.log`, assigns every line a tag (explicit `[tag]`,
# severity keyword, or module heuristic — see log_tags.rb), paints it with that
# tag's color, and drops lines whose tag is disabled.
#
# In an interactive terminal the left margin doubles as a live configurator:
# number keys toggle tags, `a`/`n` enable/disable all, `l` flips the legend,
# `r` reloads the taxonomy from disk, `?` shows the keys, `q` quits.
module AetherLog
  class Viewer
    def initialize(registry:, path:, follow: true, lines: 200, color: $stdout.tty?)
      @reg = registry
      @path = path
      @follow = follow
      @lines = lines
      @color = color && ENV['NO_COLOR'].nil?
      @quit = false
      @legend = true
      @label_width = @reg.label_width
      @keys = Queue.new
    end

    def run
      if @follow
        tail_loop
      else
        dump_once
      end
    ensure
      stop_key_listener
    end

    # ── Non-follow mode: print the last `@lines` lines once. ───────────────
    def dump_once
      ensure_file!
      File.readlines(@path).last(@lines).each { |line| render_line(line) }
    end

    # ── Follow mode ────────────────────────────────────────────────────────
    def tail_loop
      print_header
      start_key_listener if $stdin.tty?
      ensure_file!
      until @quit
        File.open(@path, 'r') do |f|
          f.seek(0, IO::SEEK_END)
          loop do
            while (line = f.gets)
              render_line(line)
            end
            process_keys
            break if @quit
            break if rotated?(f)
            sleep 0.15
          end
        end
      end
      reset_terminal
    end

    def rotated?(file)
      return false unless File.exist?(@path)
      File.size(@path) < file.pos # truncation or rename → reopen from head
    end

    def ensure_file!
      return if File.exist?(@path)
      if @follow
        warn "waiting for #{@path} … (start the server first)"
        sleep 0.5 until File.exist?(@path)
      else
        abort "No log file at #{@path}. Start the server first with: ÆtherCodex server"
      end
    end

    # ── Rendering ──────────────────────────────────────────────────────────
    def render_line(line)
      tag = @reg.tag_for(line)
      return unless @reg.enabled?(tag)

      code = @reg.color(tag)
      body = line.sub(/\A\s*\[[A-Za-z0-9_-]+\]\s*/, '').chomp
      label = "[#{tag}]".ljust(@label_width)
      if @color
        print AetherLog.ansi(code, bold: true) + label + AetherLog::RESET + ' '
        puts  AetherLog.ansi(code) + body + AetherLog::RESET
      else
        puts "#{label} #{body}"
      end
    end

    def print_header
      return unless @color && @legend
      puts AetherLog.ansi(AetherLog::PALETTE['violet'], bold: true) + 'ÆtherCodex log viewer' + AetherLog::RESET +
           " — #{@path}"
      print_legend
      puts '─' * 70
    end

    def print_legend
      return unless @legend
      @reg.names.each_with_index do |name, i|
        code = @reg.color(name)
        marker = @reg.enabled?(name) ? '●' : '○'
        entry = "#{marker} #{i + 1}:#{name}"
        print '  ' if i.positive? && (i % 4).zero?
        print AetherLog.ansi(code) + entry + AetherLog::RESET
        puts((i + 1) % 4 == 0 ? "\n" : '   ')
      end
      puts if @reg.names.size % 4 != 0
    end

    # ── Interactive keys ───────────────────────────────────────────────────
    def start_key_listener
      return if @key_thread
      require 'io/console'
      @key_thread = Thread.new do
        $stdin.raw!
        loop { @keys << $stdin.getch }
      rescue IOError, Errno::EBADF
        # stdin closed; the main loop still exits cleanly via q/EOF
      ensure
        reset_terminal
      end
    end

    def stop_key_listener
      @key_thread&.kill
      @key_thread = nil
      reset_terminal
    end

    def reset_terminal
      require 'io/console'
      $stdin.cooked!
    rescue StandardError
      nil
    end

    def process_keys
      loop do
        ch = begin
          @keys.pop(true)
        rescue ThreadError
          break
        end
        handle_key(ch)
      end
    end

    def handle_key(ch)
      case ch
      when 'q', "\u0003" then @quit = true
      when 'l' then @legend = !@legend
      when 'a' then @reg.enable_all
      when 'n' then @reg.disable_all
      when 'r' then @reg.tags.replace(AetherLog::Registry.new(path: @reg.path).tags)
      when '?' then print_help
      when '0'..'9'
        idx = ch.to_i - 1
        name = @reg.names[idx]
        @reg.toggle(name) if name
      end
    end

    def print_help
      puts '─' * 70
      puts '1-9 toggle tag   a all on   n all off   l legend   r reload   q quit'
      puts '─' * 70
    end
  end
end

# ── AetherLog::Configurator — the log tag configurator. ────────────────────
# Interactive tag editor: move with j/k (or arrows), space toggles, c cycles the
# color, s saves, r resets to defaults, q quits (auto-saves). Without a TTY it
# acts as a scriptable CLI (`list`, `toggle`, `enable`, `disable`, `color`,
# `reset`) so the taxonomy is configurable from both flesh and script.
module AetherLog
  class Configurator
    def initialize(registry)
      @reg = registry
      @idx = 0
      @dirty = false
    end

    def run(args)
      return run_cli(args) unless $stdin.tty? && $stdout.tty?
      run_interactive
    end

    # ── Interactive editor ─────────────────────────────────────────────────
    def run_interactive
      require 'io/console'
      loop do
        redraw
        ch = $stdin.getch
        case ch
        when 'q' then break
        when 'j', "\e[B" then move(1)
        when 'k', "\e[A" then move(-1)
        when ' ' then toggle_current
        when 'c' then cycle_color
        when 's' then save
        when 'r' then @reg.reset!
        when 'a' then @reg.enable_all
        when 'n' then @reg.disable_all
        end
      end
      save
    ensure
      print "\e[?25h" # restore cursor
    end

    def move(delta)
      @idx = (@idx + delta) % @reg.names.size
    end

    def toggle_current
      @reg.toggle(@reg.names[@idx])
      @dirty = true
    end

    def cycle_color
      name = @reg.names[@idx]
      names = AetherLog::PALETTE_NAMES
      cur = @reg.tags[name]['color'].to_s
      nxt = names[(names.index(cur) + 1) % names.size]
      @reg.set_color(name, nxt)
      @dirty = true
    end

    def save
      @reg.save!
      @dirty = false
    end

    def redraw
      print "\e[H\e[2J" # clear
      puts AetherLog.ansi(AetherLog::PALETTE['violet'], bold: true) + 'Log tag configurator' + AetherLog::RESET
      puts 'j/k move   space toggle   c color   a all   n none   s save   r reset   q quit'
      puts '─' * 64
      @reg.names.each_with_index do |name, i|
        cfg = @reg.tags[name]
        code = AetherLog.color_code(cfg['color'])
        cursor = i == @idx ? '▶' : ' '
        state = cfg['enabled'] ? '●' : '○'
        kind = cfg['kind'] == 'level' ? 'level ' : 'module'
        swatch = AetherLog.ansi(code) + '███' + AetherLog::RESET
        line = format('%s %s %-10s %-7s %-10s %s',
                      cursor, state, name, kind, cfg['color'], swatch)
        print AetherLog.ansi(code) + line + AetherLog::RESET
        puts
      end
      puts '─' * 64
      puts(@dirty ? 'unsaved changes' : 'clean')
      print "\e[?25l" # hide cursor
    end

    # ── Scriptable CLI ─────────────────────────────────────────────────────
    def run_cli(args)
      action = args.shift || 'list'
      case action
      when 'list' then list
      when 'toggle' then toggle_named(args[0])
      when 'enable' then set_named(args[0], true)
      when 'disable' then set_named(args[0], false)
      when 'color' then color_named(args[0], args[1])
      when 'reset' then @reg.reset! && @reg.save!
      else
        puts "Unknown logs-tags action: #{action}"
        puts 'Available: list | toggle <tag> | enable <tag> | disable <tag> | color <tag> <color> | reset'
        exit 1
      end
    end

    def list
      @reg.names.each do |name|
        cfg = @reg.tags[name]
        code = AetherLog.color_code(cfg['color'])
        state = cfg['enabled'] ? 'on ' : 'off'
        puts "#{AetherLog.ansi(code)}#{state}  #{name.ljust(10)} #{cfg['color'].to_s.ljust(8)} #{'███'}#{AetherLog::RESET}"
      end
    end

    def toggle_named(name)
      @reg.toggle(name)
      @reg.save!
    end

    def set_named(name, enabled)
      cfg = @reg[name]
      cfg['enabled'] = enabled if cfg
      @reg.save!
    end

    def color_named(name, color)
      unless @reg[name] && AetherLog::PALETTE.key?(color.to_s)
        abort "unknown tag/color. Palette: #{AetherLog::PALETTE_NAMES.join(', ')}"
      end
      @reg.set_color(name, color)
      @reg.save!
    end
  end
end