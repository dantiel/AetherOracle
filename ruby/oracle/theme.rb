# frozen_string_literal: true

require 'yaml'
require 'rouge'

# ÆtherTheme — the chamber's theme fundus.
#
# Loads the TextMate-style YAML themes that ship in `resources/Themes` and
# presents each one to the chamber in two skins:
#
#   * a semantic palette — success / fail / warn / accent / dim, drawn from the
#     theme's own scope colours (`support.constant` = success, `invalid` = fail);
#   * a Rouge theme     — registered under the theme's friendly name so fenced
#     code blocks highlight with the same scope colours.
#
# Rouge's own built-in themes stay available; for those the semantic palette
# falls back to a neutral true-colour baseline (classic terminal green/red).
module ÆtherTheme
  extend self

  THEME_DIRS = [
    File.expand_path('../../resources/Themes', __dir__),
    File.expand_path('../../resources/themes', __dir__),
    File.join(Dir.pwd, 'resources', 'Themes')
  ].uniq.freeze

  # TextMate scope → Rouge token. Curated for the scopes the bundled themes
  # actually declare; anything unknown falls back to Text.
  SCOPE_TOKENS = {
    'comment'                  => 'Comment',
    'string'                   => 'Literal.String',
    'string.escape'            => 'Literal.String.Escape',
    'string.unquoted'          => 'Literal.String',
    'string source'            => 'Literal.String',
    'keyword'                  => 'Keyword',
    'keyword.type'             => 'Keyword.Type',
    'storage'                  => 'Keyword.Type',
    'storage.type'             => 'Keyword.Type',
    'support'                  => 'Name.Builtin',
    'support.function'         => 'Name.Builtin',
    'support.class'            => 'Name.Class',
    'support.type'             => 'Keyword.Type',
    'support.constant'         => 'Name.Constant',
    'constant'                 => 'Name.Constant',
    'constant.numeric'         => 'Literal.Number',
    'constant.language'        => 'Keyword.Constant',
    'constant.character'       => 'Literal.String.Char',
    'constant.symbol'          => 'Literal.String.Symbol',
    'constant.other'           => 'Name.Constant',
    'number'                   => 'Literal.Number',
    'entity.name.class'        => 'Name.Class',
    'entity.name.function'     => 'Name.Function',
    'entity.name.tag'          => 'Name.Tag',
    'entity.name.type.namespace' => 'Name.Namespace',
    'entity.other.attribute-name' => 'Name.Attribute',
    'entity.other.inherited-class' => 'Name.Class',
    'variable'                 => 'Name.Variable',
    'variable.other'           => 'Name.Variable',
    'variable.language'        => 'Name.Variable.Global',
    'variable.instance'        => 'Name.Variable.Instance',
    'variable.class'           => 'Name.Variable.Class',
    'variable.global'          => 'Name.Variable.Global',
    'variable.parameter'       => 'Name.Variable',
    'variable.function'        => 'Name.Function',
    'function'                 => 'Name.Function',
    'property'                 => 'Name.Attribute',
    'type'                     => 'Keyword.Type',
    'operator'                 => 'Operator',
    'punctuation'              => 'Punctuation',
    'attribute'                => 'Name.Attribute',
    'tag'                      => 'Name.Tag',
    'declaration.tag'          => 'Name.Tag',
    'declaration.doctype'      => 'Comment.Preproc',
    'declaration.xml-processing' => 'Comment.Preproc',
    'preprocessor'             => 'Comment.Preproc',
    'other.preprocessor'       => 'Comment.Preproc',
    'invalid'                  => 'Generic.Error',
    'markup.heading'           => 'Generic.Heading',
    'markup.bold'              => 'Generic.Strong',
    'markup.italic'            => 'Generic.Emph',
    'plain'                    => 'Text',
    'text'                     => 'Text'
  }.freeze

  # Semantic chrome. A Palette turns one theme's colours into ready-to-print
  # ANSI escapes; `success`/`fail` are what the chamber uses for exit codes
  # and instrumenta state.
  class Palette
    DEFAULT = {
      success: '0x00cc00',
      fail:    '0xcc0000',
      warn:    '0xcc8800',
      accent:  '0x0088cc'
    }.freeze

    def initialize(colors = {})
      @colors = colors
    end

    def success(text) = color(text, @colors[:success] || DEFAULT[:success])
    def fail(text)    = color(text, @colors[:fail]    || DEFAULT[:fail])
    def warn(text)    = color(text, @colors[:warn]    || DEFAULT[:warn])
    def accent(text)  = color(text, @colors[:accent]  || DEFAULT[:accent])
    def dim(text)     = "\e[2m#{text}\e[0m"

    def color(text, hex)
      r, g, b = rgb(hex)
      "\e[38;2;#{r};#{g};#{b}m#{text}\e[0m"
    end

    private

    def rgb(hex)
      s = hex.to_s.delete_prefix('0x').delete_prefix('0X').delete_prefix('#')
      s = s[0, 6].rjust(6, '0')
      [s[0, 2].to_i(16), s[2, 2].to_i(16), s[4, 2].to_i(16)]
    end
  end

  @registry = nil

  def registry
    @registry ||= build_registry
  end

  # All fundus theme names (downcased canonical names, no Rouge built-ins).
  def names
    registry.keys
  end

  # Resolve a fundus theme by name (Rouge built-ins are NOT included here).
  def resolve(name)
    registry[name.to_s.downcase]
  end

  def palette_for(name)
    entry = resolve(name)
    entry ? entry[:palette] : Palette.new
  end

  private

  def build_registry
    reg = {}
    seen = {}
    yaml_files.each do |path|
      data = load_yaml(path)
      next unless data.is_a?(Hash)

      name = canonical_name(data)
      next if name.empty?
      next if seen[name]

      entry = build_entry(data)
      next unless entry

      seen[name] = true
      reg[name] = entry
    end
    reg
  end

  def yaml_files
    THEME_DIRS.flat_map do |dir|
      next [] unless File.directory?(dir)
      Dir[File.join(dir, '*.yml')].sort
    end
  end

  def load_yaml(path)
    YAML.load_file(path)
  rescue StandardError
    nil
  end

  def canonical_name(data)
    data['name'].to_s.strip.downcase
  end

  def build_entry(data)
    { palette: build_palette(data), rouge_class: build_rouge_theme(canonical_name(data), data) }
  rescue StandardError
    nil
  end

  def build_palette(data)
    scopes = data['scopes'] || {}
    invalid = scopes['invalid']
    Palette.new(
      success: greenest([scope_color(scopes, 'support.constant'), scope_color(scopes, 'constant')]),
      fail: reddest([invalid.is_a?(Hash) ? invalid['color'] : invalid,
                     invalid.is_a?(Hash) ? invalid['background'] : nil,
                     scope_color(scopes, 'constant.numeric'),
                     scope_color(scopes, 'number')]),
      warn:    data.dig('pythia', 'complementary'),
      accent:  data.dig('pythia', 'accent') || data.dig('pythia', 'complementary')
    )
  end

  def build_rouge_theme(name, data)
    scopes = data['scopes'] || {}
    klass = Class.new(Rouge::Theme)

    palette = { text: normalize_hex(foreground_hex(data)) || '#b8bec4' }
    hex_syms = {}
    next_sym = lambda do |hex|
      key = normalize_hex(hex)
      next nil if key.nil?
      hex_syms[key] ||= begin
        sym = "c#{hex_syms.size}".to_sym
        palette[sym] = key
        sym
      end
    end

    # First pass: register every colour so the palette is complete before it
    # is handed to Rouge — Rouge's `palette` copies on merge, so mutations made
    # after `palette(...)` are invisible to the formatter.
    scopes.each do |scope, spec|
      next_sym.call(spec.is_a?(Hash) ? spec['color'] : spec)
      next_sym.call(spec['background']) if spec.is_a?(Hash)
    end

    klass.palette(palette)
    klass.style(Rouge::Token['Text'], fg: :text)

    # Second pass: bind scopes to tokens.
    scopes.each do |scope, spec|
      token = rouge_token_for(scope)
      next if token.nil?

      style = {}
      fg = next_sym.call(spec.is_a?(Hash) ? spec['color'] : spec)
      style[:fg] = fg if fg
      if spec.is_a?(Hash)
        bg = next_sym.call(spec['background'])
        style[:bg] = bg if bg
        style[:bold] = true if spec['bold']
        style[:italic] = true if spec['italic']
        style[:underline] = true if spec['underline']
      end
      klass.style(token, style) if style.any?
    end

    klass.name(name)
    klass
  end

  def rouge_token_for(scope)
    token = SCOPE_TOKENS[scope.to_s]
    return Rouge::Token[token] if token

    parts = scope.to_s.split('.')
    while parts.any?
      parts.pop
      t = SCOPE_TOKENS[parts.join('.')]
      return Rouge::Token[t] if t
    end
    nil
  end

  def scope_color(scopes, name)
    v = scopes[name]
    return nil if v.nil?
    v.is_a?(Hash) ? (v['color'] || v[:color]) : v
  end

  def greenest(candidates)
    pick_by_score(candidates) { |hex| channel_dominance(hex, :green) }
  end

  def reddest(candidates)
    pick_by_score(candidates) { |hex| channel_dominance(hex, :red) }
  end

  def pick_by_score(candidates)
    best = nil
    best_score = 0
    candidates.each do |hex|
      score = yield(hex)
      next if score.nil? || score <= 0
      if score > best_score
        best_score = score
        best = hex
      end
    end
    best
  end

  # Returns the dominance of one channel over the other two (positive = that
  # channel leads), so a "red" colour scores red >> green/blue, etc.
  def channel_dominance(hex, channel)
    r, g, b = rgb_ints(hex)
    return nil if r.nil?
    case channel
    when :red   then r - [g, b].max
    when :green then g - [r, b].max
    when :blue  then b - [r, g].max
    end
  end

  def rgb_ints(hex)
    s = normalize_hex(hex)
    return [nil, nil, nil] unless s
    [s[0, 2].to_i(16), s[2, 2].to_i(16), s[4, 2].to_i(16)]
  end

  def foreground_hex(data)
    editor = data['editor'] || {}
    editor['foreground'] || data['editorForeground'] ||
      data.dig('pythia', 'foreground') || '#b8bec4'
  end

  def normalize_hex(hex)
    s = hex.to_s.strip
    return nil if s.empty?
    s = s.delete_prefix('0x').delete_prefix('0X').delete_prefix('#')
    s = s[0, 6]
    s.match?(/\A[0-9a-fA-F]{6}\z/) ? s : nil
  end
end