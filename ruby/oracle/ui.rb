# frozen_string_literal: true

# AthanorUI — box-drawing and table primitives for the Dialog-Kammer's chrome.
#
# The chamber's own framing (banner, help, personae list, config/cost/context
# summaries, tool list) renders through these helpers so the REPL reads as a
# real UI instead of a wall of bare `puts` lines. Unicode box-drawing is safe
# here because the interactive console is forced to UTF-8 up front
# (ÆtherChamber#force_utf8_console). The captured-output pane (instrumentum
# results) deliberately stays 7-bit ASCII — that path still mangles multi-byte
# glyphs into mojibake (see note 49).
#
# Every helper returns an Array of already-styled Strings; callers just `puts`
# the result. They are pure functions of their inputs and never touch @stdout.
module AthanorUI
  H  = '─'
  V  = '│'
  TL = '╭'
  TR = '╮'
  BL = '╰'
  BR = '╯'
  LT = '├'
  RT = '┤'
  X  = '┼'

  # SGR sequences only — sufficient for the chrome we generate.
  ANSI = /\e\[[0-9;]*m/.freeze

  module_function

  def strip_ansi(str)
    str.to_s.gsub(ANSI, '')
  end

  def char_width(ch)
    cp = ch.ord
    return 2 if cp.between?(0x1F000, 0x1FAFF) # emoji
    return 2 if cp.between?(0x2E80, 0x9FFF)   # CJK
    return 2 if cp.between?(0xAC00, 0xD7A3)   # Hangul
    return 2 if cp.between?(0xF900, 0xFAFF)
    return 2 if cp.between?(0xFE30, 0xFE4F)
    return 2 if cp.between?(0xFF00, 0xFF60)
    return 2 if cp.between?(0xFFE0, 0xFFE6)

    1
  end

  def display_width(str)
    strip_ansi(str).each_char.sum { |ch| char_width(ch) }
  end

  # Pad `str` with trailing spaces to exactly `width` visible columns.
  def pad(str, width)
    s = str.to_s
    s + (' ' * [width - display_width(s), 0].max)
  end

  # ANSI-safe truncation to `width` visible columns; appends a single ellipsis
  # when clipped. Escape sequences are never split in half.
  def trunc(str, width)
    s = str.to_s
    return s if display_width(s) <= width
    return '' if width <= 0

    out = +''
    visible = 0
    rest = s.dup
    limit = width - 1
    while visible < limit && !rest.empty?
      if (m = rest.match(/\A\e\[[0-9;]*m/))
        out << m[0]
        rest = rest[m[0].length..]
        next
      end
      ch = rest[0]
      out << ch
      visible += char_width(ch)
      rest = rest[1..]
    end
    out << '…' << "\e[0m"
  end

  # A titled, single-line-bordered box. `rows` are pre-styled display strings,
  # clipped (not wrapped) to fit the inner width.
  def box(title, rows, width:, palette:)
    w = [width, 2].max
    inner = [w - 2, 0].max
    field = [inner - 2, 0].max

    has_title = !title.to_s.empty?
    body = Array(rows)

    out = [palette.accent(TL + (H * inner) + TR)]
    if has_title
      out << palette.accent(V) + ' ' + pad(trunc(title, field), field) + ' ' + palette.accent(V)
      out << palette.accent(LT + (H * inner) + RT) if body.any?
    end
    body.each do |row|
      out << palette.accent(V) + ' ' + pad(trunc(row, field), field) + ' ' + palette.accent(V)
    end
    out << palette.accent(BL + (H * inner) + BR)
    out
  end

  # Two-column key/value lines, aligned on the value column (for config-style
  # panels). Returns plain (already dim-styled key) strings, ready for `box`.
  def kv(rows, palette:)
    key_w = rows.map { |k, _| display_width(k.to_s) }.max.to_i
    rows.map { |k, v| palette.dim(pad(k.to_s, key_w)) + '  ' + v.to_s }
  end

  # A grid table with a styled header row and a `├──┼──┤` separator. Column
  # widths auto-fit to content and shrink (widest first) to respect `width`.
  def table(headers, rows, width:, palette:)
    all = [headers.map(&:to_s)] + rows.map { |r| r.map(&:to_s) }
    cols = all.first.size
    return [] if cols.zero?

    widths = Array.new(cols, 0)
    all.each { |r| r.each_with_index { |c, i| widths[i] = [widths[i], display_width(c)].max } }
    widths.map! { |w| w + 2 } # one space of padding on each side

    sep = 1
    inner = [width - 2, 2].max
    total = widths.sum + (sep * (cols - 1))
    if total > inner
      excess = total - inner
      while excess.positive?
        i = widths.each_index.max_by { |j| widths[j] }
        break if widths[i] <= 3

        widths[i] -= 1
        excess -= 1
      end
    end
    content = [widths.sum + (sep * (cols - 1)), inner].min

    row_line = lambda do |cells, style|
      body = cells.each_with_index.map do |c, i|
        pad(' ' + trunc(c, widths[i] - 2) + ' ', widths[i])
      end.join(' ' * sep)
      palette.accent(V) + style.call(body) + palette.accent(V)
    end

    header_sep_inner = widths.each_with_index.map { |w, i| (H * w) + (i == cols - 1 ? '' : X) }.join
    [
      palette.accent(TL + (H * content) + TR),
      row_line.call(headers, ->(b) { "\e[1m#{b}\e[0m" }),
      palette.accent(LT + header_sep_inner + RT),
      *rows.map { |r| row_line.call(r, ->(b) { b }) },
      palette.accent(BL + (H * content) + BR)
    ]
  end
end