# frozen_string_literal: true

require 'rouge'

# ÆtherTerminalMarkdown -- renders Markdown to ANSI-colored terminal output.
#
# A dependency-light terminal markdown engine: it speaks the same dialect as
# the HTML renderer (fenced code, tables, headings, lists, quotes, links) but
# emits ANSI escape sequences instead of HTML, and pipes code blocks through
# Rouge so they arrive syntax-highlighted in the chamber.
#
# It is deliberately self-contained so the dialog chamber never depends on a
# heavier TTY stack -- Rouge is the only requirement (already a core dependency).
module ÆtherTerminalMarkdown
  extend self

  # Matches the <file> tag the oracle emits for file references:
  #   <file>path</file>  or  <file path="p" line="1" column="2">label</file>
  FILE_TAG_RE = %r{<file(?:\s+path="(?<path>[^"]*)")?(?:\s+line="(?<line>\d+)")?(?:\s+column="(?<column>\d+)")?>(?<label>[^<]*)</file>}i

  # ANSI SGR palette (16-color baseline; every terminal honors these).
  module Paint
    RESET      = "\e[0m"
    BOLD       = "\e[1m"
    DIM        = "\e[2m"
    ITALIC     = "\e[3m"
    UNDERLINE  = "\e[4m"
    STRIKE     = "\e[9m"

    BLACK   = "\e[30m"; RED     = "\e[31m"; GREEN  = "\e[32m"; YELLOW = "\e[33m"
    BLUE    = "\e[34m"; MAGENTA = "\e[35m"; CYAN   = "\e[36m"; WHITE  = "\e[37m"
    GRAY    = "\e[90m"

    module_function

    def wrap(text, *codes)
      return text.to_s if text.to_s.empty?
      "#{codes.join}#{text}#{RESET}"
    end

    def bold(text)   = wrap(text, BOLD)
    def dim(text)    = wrap(text, DIM)
    def italic(text) = wrap(text, ITALIC)
    def underline(text) = wrap(text, UNDERLINE)
    def strike(text) = wrap(text, STRIKE)

    def color(text, code) = wrap(text, code)
  end

  # Themes map friendly names to Rouge theme classes. Only themes that ship
  # inside Rouge itself are listed so no extra dependency is ever needed.
  THEMES = {
    'monokai'   => Rouge::Themes::Monokai,
    'github'    => Rouge::Themes::Github,
    'gruvbox'   => Rouge::Themes::Gruvbox,
    'base16'    => Rouge::Themes::Base16,
    'colorful'  => Rouge::Themes::Colorful,
    'thankful'  => Rouge::Themes::ThankfulEyes,
    'molokai'   => Rouge::Themes::Molokai,
    'magritte'  => Rouge::Themes::Magritte,
    'pastie'    => Rouge::Themes::Pastie,
    'tulip'     => Rouge::Themes::Tulip,
    'igor'      => Rouge::Themes::IgorPro,
    'monokai_sublime' => Rouge::Themes::MonokaiSublime
  }.freeze

  # Rouge may ship a slightly different theme name across versions -- resolve
  # with tolerance rather than dying on a missing constant.
  def self.resolve_theme(name)
    key = name.to_s.downcase
    THEMES[key] ||
      fundus_theme(key) ||
      Rouge::Theme.registry[key] ||
      begin
        const_name = name.to_s.split(/[_\s-]/).map(&:capitalize).join
        Rouge::Themes.const_get(const_name) if Rouge::Themes.const_defined?(const_name)
      end
  rescue StandardError
    nil
  end

  # ÆtherTheme is loaded by the chamber after this file; guard the reference so
  # a bare `render` never hard-requires it. Building the fundus registry also
  # registers each YAML theme as a Rouge theme.
  def self.fundus_theme(key)
    return nil unless defined?(ÆtherTheme) && ÆtherTheme.respond_to?(:resolve)
    ÆtherTheme.resolve(key)&.dig(:rouge_class)
  end

  # A Rouge formatter that emits 256-color ANSI and falls back to a plain
  # terminal formatter when the theme can't be found.
  class CodeHighlighter
    def initialize(theme_name = nil)
      @formatter = build_formatter(theme_name)
    end

    def format(lexer, code)
      @formatter.format(lexer.lex(code))
    rescue StandardError
      Rouge::Formatters::Terminal256.new.format(lexer.lex(code))
    rescue StandardError
      code
    end

    private

    def build_formatter(theme_name)
      theme = theme_name ? ÆtherTerminalMarkdown.resolve_theme(theme_name) : nil
      theme ? Rouge::Formatters::Terminal256.new(theme.new) : Rouge::Formatters::Terminal256.new
    rescue StandardError
      Rouge::Formatters::Terminal256.new
    end
  end

  def lexer_for(language)
    return Rouge::Lexers::PlainText.new if language.nil? || language.strip.empty?

    Rouge::Lexer.find_fancy(language) || Rouge::Lexers::PlainText.new
  rescue StandardError
    Rouge::Lexers::PlainText.new
  end

  # Render full markdown to a terminal string.
  def render(markdown, theme: nil, width: nil)
    width ||= detect_width
    highlighter = CodeHighlighter.new(theme)
    out = []

    in_code    = false
    code_lang  = nil
    code_lines = []
    in_table   = false
    table_rows = []

    flush_code = lambda do
      return unless in_code
      code = code_lines.join("\n").chomp
      lexer = lexer_for(code_lang)
      rendered = highlighter.format(lexer, code).chomp
      out << render_code_block(rendered)
      code_lines = []
      code_lang = nil
      in_code = false
    end

    flush_table = lambda do
      return unless in_table
      out << render_table(table_rows, width)
      table_rows = []
      in_table = false
    end

    markdown.to_s.each_line do |raw|
      line = raw.chomp

      # Fenced code block open/close
      if (m = line.match(/^\s*```+\s*([\w.+#-]*)\s*$/))
        if in_code
          flush_code.call
        else
          flush_table.call
          in_code = true
          code_lang = m[1].to_s.strip
        end
        next
      end

      if in_code
        code_lines << raw
        next
      end

      # Table detection: a row of pipes followed by a separator row.
      if table_row?(line)
        flush_table.call unless in_table
        in_table = true
        table_rows << line
        next
      end
      if in_table && line.match?(/^\s*\|?[\s:|-]+\|[\s:|-]*$/)
        table_rows << line
        next
      end
      if in_table && table_rows.length == 2 && separator_only?(table_rows.last)
        # Keep the header + separator; the next data line continues the table.
        next
      end
      flush_table.call if in_table && !table_row?(line)

      if (m = line.match(/^\s{0,3}(\#{1,6})\s+(.*)$/))
        out << render_heading(m[1].length, m[2])
      elsif (m = line.match(/^\s*([-*_])(\s*\1){2,}\s*$/))
        out << Paint.dim('-' * [width, 12].max)
      elsif (m = line.match(/^\s{0,3}>\s?(.*)$/))
        out << render_blockquote(m[1])
      elsif (m = line.match(/^\s*[-*+]\s+(.*)$/))
        out << render_list_item(m[1], '-')
      elsif (m = line.match(/^\s*\d+[.)]\s+(.*)$/))
        num = m[0].match(/\d+/)[0]
        out << render_list_item(m[1], "#{num}.")
      elsif line.strip.empty?
        out << ''
      else
        out << render_inline(line)
      end
    end

    flush_code.call
    flush_table.call
    out.join("\n")
  end

  # Render a single line's worth of markdown inline spans.
  def render_inline(text)
    text = text.to_s
    text = file_tags(text)
    text = inline_code(text)
    text = bold(text)
    text = italic(text)
    text = strike(text)
    text = links(text)
    text
  end

  # Extract file references from markdown for the interactive navigator: every
  # <file> tag plus markdown links that resolve to an existing file path.
  def extract_file_links(markdown)
    found = []
    markdown.to_s.scan(FILE_TAG_RE) do
      m = Regexp.last_match
      path = m[:path].to_s.strip
      path = m[:label].to_s.strip if path.empty?
      next if path.empty?

      found << { path: path, line: m[:line], column: m[:column], label: m[:label].to_s.strip }
    end
    markdown.to_s.scan(/\[([^\]]+)\]\(([^)]+)\)/) do
      label = Regexp.last_match(1)
      url = Regexp.last_match(2)
      path = url.to_s.split('#').first.to_s.strip
      next if path.empty? || url.to_s.match?(%r{\A(?:https?|ftp)://}i)
      next unless File.exist?(path)

      found << { path: path, line: nil, column: nil, label: label }
    end
    found.uniq { |l| [l[:path], l[:line], l[:column]] }
  end

  private

  def detect_width
    require 'io/console'
    IO.console&.winsize&.last
  rescue StandardError
    nil
  end || 88

  def inline_code(text)
    text.gsub(/`([^`]+)`/) { Paint.wrap($1, Paint::CYAN) }
  end

  def bold(text)
    text.gsub(/\*\*([^*]+)\*\*/) { Paint.bold($1) }
  end

  def italic(text)
    text.gsub(/(?<!\*)\*([^*\n]+)\*(?!\*)/) { Paint.italic($1) }
  end

  def strike(text)
    text.gsub(/~~([^~]+)~~/) { Paint.strike($1) }
  end

  def links(text)
    text.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
      label = $1
      url = $2
      path = url.split('#').first.to_s
      if url !~ %r{\A(?:https?|ftp)://}i && fileish?(path)
        file_link(path, nil, nil, label)
      else
        "#{Paint.wrap(label, Paint::UNDERLINE, Paint::BLUE)}#{Paint.dim(" #{url}")}"
      end
    end
  end

  # Turn a <file> tag into a clickable OSC 8 hyperlink (file:// URI).
  def file_tags(text)
    text.gsub(FILE_TAG_RE) do
      m = Regexp.last_match
      path = m[:path].to_s.strip
      path = m[:label].to_s.strip if path.empty?
      next m[0] if path.empty?

      label = m[:label].to_s.strip
      label = "#{path}#{m[:line] ? ":#{m[:line]}" : ''}#{m[:line] && m[:column] ? ":#{m[:column]}" : ''}" if label.empty?
      file_link(path, m[:line], m[:column], label)
    end
  end

  def file_link(path, line = nil, column = nil, label = nil)
    target = "#{path}#{line ? ":#{line}" : ''}#{line && column ? ":#{column}" : ''}"
    label ||= target
    return Paint.wrap(label, Paint::UNDERLINE, Paint::BLUE) unless hyperlinks?

    "\e]8;;file:///#{absolute_path(path)}\a#{Paint.wrap(label, Paint::UNDERLINE, Paint::BLUE)}\e]8;;\a"
  end

  def hyperlinks?
    ENV['AETHER_NO_LINKS'].to_s.empty?
  end

  def absolute_path(path)
    File.expand_path(path).tr('\\', '/')
  rescue StandardError
    path
  end

  def fileish?(path)
    path && !path.empty? && (File.exist?(path) || path.match?(%r{\A[./~]}))
  end

  def render_heading(level, text)
    rendered = Paint.bold(render_inline(text))
    case level
    when 1 then Paint.wrap(rendered, Paint::MAGENTA, Paint::BOLD)
    when 2 then Paint.wrap(rendered, Paint::CYAN, Paint::BOLD)
    when 3 then Paint.wrap(rendered, Paint::GREEN, Paint::BOLD)
    when 4 then Paint.wrap(rendered, Paint::YELLOW, Paint::BOLD)
    else Paint.bold(rendered)
    end
  end

  def render_code_block(rendered)
    lines = rendered.lines.map { |l| "  #{l.chomp}" }
    header = Paint.dim('+- code -')
    footer = Paint.dim('+-------')
    [header, lines.join("\n"), footer].join("\n")
  end

  def render_blockquote(text)
    Paint.wrap("| #{render_inline(text)}", Paint::DIM)
  end

  def render_list_item(text, bullet)
    "  #{Paint.color(bullet, Paint::CYAN)} #{render_inline(text)}"
  end

  def table_row?(line)
    line.include?('|') && !line.strip.start_with?('```')
  end

  def separator_only?(line)
    line.match?(/^\s*\|?\s*:?-{2,}.*\|\s*$/) && line.match?(/^[\s:|-]+$/)
  end

  def parse_table_row(line)
    line.strip.sub(/^\|/, '').sub(/\|$/, '').split('|').map(&:strip)
  end

  def render_table(rows, width)
    return '' if rows.empty?

    header = parse_table_row(rows.first)
    body = rows.drop(1).reject { |r| separator_only?(r) }.map { |r| parse_table_row(r) }
    cols = header.length

    widths = Array.new(cols, 0)
    ([header] + body).each do |row|
      row.each_with_index { |cell, i| widths[i] = [widths[i], visible_length(cell)].max }
    end
    widths.map! { |w| [w, 3].max }

    out = []
    out << render_table_row(header, widths, header: true)
    out << Paint.dim(render_table_border(widths))
    body.each { |row| out << render_table_row(row, widths) }
    out.join("\n")
  end

  def render_table_border(widths)
    widths.map { |w| '-' * (w + 2) }.join('+').then { |b| "  +#{b}+" }
  end

  def render_table_row(row, widths, header: false)
    cells = widths.each_with_index.map do |w, i|
      cell = (row[i] || '').to_s
      cell = cell.ljust(w + (visible_length(cell) - cell.length)) if cell.length < w
      cell.ljust(w)
    end
    sep = header ? Paint.color('|', Paint::CYAN) : Paint.dim('|')
    line = cells.map { |c| header ? Paint.bold(c) : c }.join(" #{sep} ")
    Paint.dim('  +') + line + Paint.dim('+')
  end

  # Length of a string once ANSI escape sequences are removed -- so column
  # padding measures the *visible* width, not the raw byte width.
  def visible_length(str)
    str.to_s.gsub(/\e\[[0-9;]*m/, '').length
  end
end