# frozen_string_literal: true

require 'yaml'
require 'fileutils'

# ── AetherLog — the tagged taxonomy of the log stream. ─────────────────────
# A "tag" is simultaneously a log level and a log module: the same token both
# paints a line and gates it. The viewer colors each line by its tag and drops
# lines whose tag is disabled. Tags, their colors and their enabled state are
# editable through the configurator (`ÆtherCodex logs tags`) and persisted to a
# YAML file, so the taxonomy is as mutable as the corpus itself.
#
# A line is tagged by priority:
#   1. an explicit `[tag]` prefix (any known tag),
#   2. a severity keyword (ERROR/WARN/INFO/DEBUG/TRACE/FATAL),
#   3. a module heuristic (Sinatra/Thin → network, tool names → tool, …),
#   4. the fallback tag `info`.
module AetherLog
  # Named ANSI-256 palette. Values are 256-color indices; the renderer emits
  # SGR 38;5;<n>m. Order doubles as the cycle order of the configurator.
  PALETTE = {
    'white'   => 15,  'silver' => 250, 'gray'   => 245, 'slate' => 102,
    'red'     => 196, 'crimson' => 160, 'rose'  => 203, 'orange' => 208,
    'amber'   => 178, 'gold'   => 220, 'yellow' => 226, 'lime'  => 118,
    'green'   => 42,  'teal'   => 43,  'cyan'   => 51,  'sky'   => 75,
    'blue'    => 33,  'indigo' => 63,  'violet' => 141, 'purple' => 129,
    'magenta' => 201, 'pink'   => 213, 'brown'  => 137
  }.freeze

  PALETTE_NAMES = PALETTE.keys.freeze

  # Default taxonomy: severity tags first, then module tags. The order is the
  # legend order; `kind` only groups them in the configurator.
  DEFAULT_TAGS = {
    'fatal'   => { color: 'magenta', enabled: true,  kind: :level  },
    'error'   => { color: 'red',     enabled: true,  kind: :level  },
    'warn'    => { color: 'gold',    enabled: true,  kind: :level  },
    'info'    => { color: 'cyan',    enabled: true,  kind: :level  },
    'debug'   => { color: 'silver',  enabled: true,  kind: :level  },
    'trace'   => { color: 'gray',    enabled: false, kind: :level  },
    'daemon'  => { color: 'white',   enabled: true,  kind: :module },
    'oracle'  => { color: 'violet',  enabled: true,  kind: :module },
    'tool'    => { color: 'sky',     enabled: true,  kind: :module },
    'memory'  => { color: 'green',   enabled: true,  kind: :module },
    'network' => { color: 'orange',  enabled: true,  kind: :module },
    'shell'   => { color: 'amber',   enabled: true,  kind: :module },
    'link'    => { color: 'teal',    enabled: true,  kind: :module },
    'config'  => { color: 'slate',   enabled: true,  kind: :module }
  }.freeze

  LEVEL_RE = /\b(FATAL|ERROR|WARN(?:ING)?|INFO|DEBUG|TRACE)\b/i

  MODULE_RULES = [
    [%r{GET |POST |PUT |DELETE |Sinatra|Thin|WebSocket|Faye|HTTP|127\.0\.0\.1|::1|socket|listen}, 'network'],
    [%r{tool_|tool call|⚒|🔧|⚡|command_|run_command}, 'tool'],
    [%r{memory|mnemosyne|aegis|recall|remember|note|Metempsychosis}, 'memory'],
    [%r{ÆtherLink|aether_link|peer|discover|context}, 'link'],
    [%r{config|CFG|\.aethercodex|CONFIG}, 'config'],
    [%r{shell|ShellSession|\$ }, 'shell'],
    [%r{oracle|conjuration|revelation|divination|conduit|repl}, 'oracle'],
    [%r{daemon|PID|signal|boot|startup|shutdown|worker|spawn}, 'daemon']
  ].freeze

  RESET = "\e[0m".freeze

  module_function

  # SGR prefix for a 256-color index. `bold` doubles the color's presence so the
  # tag label reads as a header even on low-contrast terminals.
  def ansi(code, bold: false)
    "\e[#{bold ? 1 : 0};38;5;#{code}m"
  end

  # Accept a palette name, a raw 256-color index, or an arbitrary integer string.
  def color_code(name_or_index)
    return name_or_index if name_or_index.is_a?(Integer)
    PALETTE.fetch(name_or_index.to_s, 245)
  end

  # ── Registry: the mutable, persisted state of the taxonomy. ──────────────
  class Registry
    attr_reader :tags

    def initialize(path: nil)
      @path = path || self.class.default_path
      @tags = load
    end

    def self.default_path
      ENV['AETHER_LOG_TAGS'] || File.join(Dir.home, '.tm-ai', 'log-tags.yml')
    end

    def path
      @path
    end

    # ── Load / save ────────────────────────────────────────────────────────
    def load
      base = normalize(DEFAULT_TAGS)
      return base unless File.file?(@path)

      raw = File.read(@path)
      user = begin
        YAML.safe_load(raw, permitted_classes: [], aliases: false)
      rescue Psych::Exception
        {}
      end
      return base unless user.is_a?(Hash)

      user.each do |name, opts|
        opts = {} unless opts.is_a?(Hash)
        base[name.to_s] ||= { 'color' => 'gray', 'enabled' => true, 'kind' => 'module' }
        base[name.to_s]['color']   = opts['color'].to_s if opts['color']
        base[name.to_s]['enabled'] = !!opts['enabled']  unless opts['enabled'].nil?
        base[name.to_s]['kind']    = (opts['kind'] || 'module').to_s
      end
      base
    end

    # Persist only the deltas against DEFAULT_TAGS, so future default changes
    # still reach users who have customized a single tag.
    def save!
      overrides = {}
      @tags.each do |name, cfg|
        def_cfg = DEFAULT_TAGS[name]
        if def_cfg.nil?
          overrides[name] = { 'color' => cfg['color'], 'enabled' => cfg['enabled'], 'kind' => cfg['kind'] }
        else
          diff = {}
          diff['color']   = cfg['color']   if cfg['color']   != def_cfg[:color].to_s
          diff['enabled'] = cfg['enabled'] if cfg['enabled'] != def_cfg[:enabled]
          diff['kind']    = cfg['kind']    if cfg['kind']    != def_cfg[:kind].to_s
          overrides[name] = diff unless diff.empty?
        end
      end
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, YAML.dump(overrides))
      self
    end

    # ── Queries ────────────────────────────────────────────────────────────
    def names
      @tags.keys
    end

    def [](name)
      @tags[name.to_s]
    end

    def enabled?(name)
      cfg = @tags[name.to_s]
      cfg ? cfg['enabled'] : true
    end

    def color(name)
      AetherLog.color_code(@tags.dig(name.to_s, 'color'))
    end

    def label_width
      [names.map(&:length).max.to_i, 5].max + 2 # + brackets
    end

    # ── Tag inference ──────────────────────────────────────────────────────
    def tag_for(line)
      if (m = line.match(/\A\s*\[([A-Za-z0-9_-]+)\]\s*/))
        tag = m[1].downcase
        return tag if @tags.key?(tag)
      end
      if (m = line.match(AetherLog::LEVEL_RE))
        return m[1].downcase
      end
      AetherLog::MODULE_RULES.each do |re, tag|
        return tag if line.match?(re)
      end
      'info'
    end

    # ── Mutations (used by the configurator) ───────────────────────────────
    def toggle(name)
      cfg = @tags[name.to_s]
      cfg['enabled'] = !cfg['enabled'] if cfg
    end

    def set_color(name, color)
      cfg = @tags[name.to_s]
      cfg['color'] = color.to_s if cfg && AetherLog::PALETTE.key?(color.to_s)
    end

    def enable_all
      @tags.each_value { |cfg| cfg['enabled'] = true }
    end

    def disable_all
      @tags.each_value { |cfg| cfg['enabled'] = false }
    end

    def reset!
      @tags = normalize(DEFAULT_TAGS)
    end

    private

    # Convert DEFAULT_TAGS' symbol-keyed configs into the string-keyed shape the
    # registry reads, writes and persists throughout.
    def normalize(tags)
      tags.each_with_object({}) do |(name, cfg), acc|
        acc[name.to_s] = {
          'color'   => cfg.fetch(:color, 'gray').to_s,
          'enabled' => cfg.fetch(:enabled, true),
          'kind'    => cfg.fetch(:kind, :module).to_s
        }
      end
    end
  end
end