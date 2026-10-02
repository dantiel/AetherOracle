# frozen_string_literal: true

require_relative 'theme'

# InstrumentumRenderer — shared tool-aware rendering for instrumenta results.
#
# Mixed into both ÆtherChamber (Fokus-Ring previews, Enter-to-pin) and
# TerminalStream (the live tool telemetry in the normal chat flow), so a
# read_file / run_command / patch_file / … is always shown as an illuminated
# panel — glyph, coloured status, tool-aware body — instead of a raw truncated
# JSON blob. Single source of truth for how an instrumentum result looks.
module InstrumentumRenderer
  # Glyphs for the core instrumenta — a single ASCII symbol per act, so a
  # panel reads as `$ exit 0` or `+ path.rb` instead of a bare tool name.
  # (Non-ASCII glyphs are deliberately avoided: the captured-output pane
  # mangles emoji and box-drawing chars into mojibake — see note 48.)
  INSTRUMENTUM_GLYPHS = {
    'aegis'         => 'ae',
    'read_file'     => '->',
    'run_command'   => '$',
    'create_file'   => '+',
    'patch_file'    => '~',
    'file_overview' => '@',
    'recall_notes'  => '?',
    'remember'      => '*'
  }.freeze

  # How many body lines a panel shows before collapsing.
  MAX_PREVIEW_LINES = 60

  # The host supplies a themed palette via @palette; fall back to the neutral
  # default so the renderer is usable even without one wired in.
  def palette
    @palette ||= ÆtherTheme::Palette.new
  end

  # The one-line header every panel collapses to: glyph, tool name, and a
  # coloured one-line digest (exit status / line count / edit count / …).
  def instrumentum_header(el)
    name = el[:name].to_s
    glyph = el[:glyph] || INSTRUMENTUM_GLYPHS[name] || '*'
    "\e[1;36m  #{glyph}\e[0m  #{status_suffix(el)}"
  end

  # Render an instrumentum result as an illuminated panel. `minified: true`
  # yields just the header line — the collapsed state used in the live tool
  # telemetry and the Fokus-Ring preview; the full body appears on demand
  # (Enter, or →/↑ while the element is focused).
  def instrumentum_panel(el, max_lines: MAX_PREVIEW_LINES, minified: false)
    lines = [instrumentum_header(el)]
    return lines if minified

    instrumentum_body(el, max_lines: max_lines).each do |body|
      lines << "  #{body}"
    end
    lines
  end

  # One-line digest shown in the prompt label and panel header.
  def instrumentum_summary(el)
    result = el[:result]
    if result.is_a?(Hash) && result[:error]
      err = result[:error].to_s.gsub(/\s+/, ' ').strip
      return err.empty? ? 'fehlgeschlagen' : err[0, 80]
    end

    args = el[:args] || {}
    case el[:name].to_s
    when 'read_file'
      content = result.is_a?(Hash) ? result[:content] : result
      path = args[:path].to_s
      base = "#{content.to_s.lines.size} Zeilen"
      path.empty? ? base : "#{path} - #{base}"
    when 'run_command'
      code = result.is_a?(Hash) ? result[:exit_status] : nil
      code.nil? ? 'ausgeführt' : "exit #{code}"
    when 'patch_file'
      n = args[:diff].to_s.scan(/<<<<<<< SEARCH/).size
      path = args[:path].to_s
      base = "#{n} Edit#{n == 1 ? '' : 's'}"
      path.empty? ? base : "#{base} - #{path}"
    when 'remember'
      snippet = args[:content].to_s.gsub(/\s+/, ' ')[0, 40]
      snippet.empty? ? 'gespeichert' : snippet
    when 'aegis'
      notes = result.is_a?(Hash) ? (result[:aegis_notes] || []) : []
      "#{notes.size} Notizen"
    when 'file_overview'
      fi = result.is_a?(Hash) ? result[:file_info] : nil
      path = (fi.is_a?(Hash) ? fi[:path] : args[:path]).to_s
      lines = fi.is_a?(Hash) ? fi[:lines] : nil
      base = path.empty? ? 'überblickt' : path
      lines ? "#{base} - #{lines} Zeilen" : base
    else
      text = result.is_a?(Hash) ? (result[:result] || result.inspect) : result.to_s
      text.to_s.gsub(/\s+/, ' ')[0, 40]
    end
  end

  # Compact digest of a tool call's *arguments* for the live start line
  # (path / cmd / query), so the streaming telemetry shows what is being
  # touched before the result arrives.
  def instrumentum_args_summary(el)
    args = el[:args] || {}
    digest = case el[:name].to_s
             when 'read_file'      then file_header(args)
             when 'run_command'    then args[:cmd].to_s
             when 'patch_file'     then args[:path].to_s
             when 'create_file'    then args[:path].to_s
             when 'rename_file'    then "#{args[:from]} -> #{args[:to]}"
             when 'file_overview'  then args[:path].to_s
             when 'recall_notes'   then args[:query].to_s
             when 'remember'       then args[:content].to_s.gsub(/\s+/, ' ')[0, 40]
             else ''
             end
    digest.to_s.gsub(/\s+/, ' ').strip.truncate(72)
  end

  def status_suffix(el)
    text = "(#{instrumentum_summary(el)})"
    instrumentum_ok?(el[:result]) ? palette.success(text) : palette.fail(text)
  end

  def instrumentum_ok?(result)
    return false if result.is_a?(Hash) && result[:error]
    return result[:exit_status].to_i.zero? if result.is_a?(Hash) && !result[:exit_status].nil?

    true
  end

  def instrumentum_body(el, max_lines:)
    name = el[:name].to_s
    case name
    when 'read_file'   then read_file_body(el, max_lines: max_lines)
    when 'run_command' then run_command_body(el, max_lines: max_lines)
    when 'remember'    then remember_body(el)
    when 'patch_file'  then patch_file_body(el, max_lines: max_lines)
    when 'aegis'         then aegis_body(el[:result], max_lines: max_lines)
    when 'file_overview' then file_overview_body(el, max_lines: max_lines)
    else generic_instrumentum_body(el[:result], max_lines: max_lines)
    end
  end

  def read_file_body(el, max_lines:)
    result = el[:result]
    return [palette.fail(result[:error])] if result.is_a?(Hash) && result[:error]
    content = result.is_a?(Hash) ? result[:content].to_s : result.to_s
    out = []
    header = file_header(el[:args])
    out << "\e[2m#{header}\e[0m" unless header.empty?
    out << '' if out.any? && !content.strip.empty?
    out.concat(content.strip.empty? ? ['(leer)'] : cap_lines(content, max_lines: max_lines))
    out
  end

  def run_command_body(el, max_lines:)
    result = el[:result]
    return [palette.fail(result[:error])] if result.is_a?(Hash) && result[:error]
    args = el[:args] || {}
    out = []
    cmd = args[:cmd].to_s
    out << "\e[2m$ #{cmd}\e[0m" unless cmd.empty?
    return (out << result.to_s) unless result.is_a?(Hash)
    code = result[:exit_status]
    exit_txt = "exit #{code}"
    exit_txt = code.to_i.zero? ? palette.success(exit_txt) : palette.fail(exit_txt)
    meta = +exit_txt
    meta << " - \e[2mcwd #{result[:cwd]}\e[0m" if result[:cwd] && !result[:cwd].to_s.empty?
    out << '' if out.any?
    out << meta
    raw = result[:result].to_s.sub(/\ACommand output:\s*/, '')
    lines = cap_lines(raw, max_lines: max_lines)
    out.concat([''] + lines) unless lines.empty?
    out
  end

  def file_header(args)
    args ||= {}
    path = args[:path].to_s
    return '' if path.empty?

    range = args[:range]
    suffix = range.is_a?(Array) && range.size == 2 ? "[#{range.join('..')}]" : ''
    "#{path}#{suffix}"
  end

  def remember_body(el)
    result = el[:result]
    return [palette.fail(result[:error])] if result.is_a?(Hash) && result[:error]
    args = el[:args] || {}
    id = args[:id] || (result.is_a?(Hash) ? result[:id] : nil)
    out = ["\e[1m#{id ? "Notiz ##{id}" : 'Notiz'}\e[0m"]
    content = args[:content].to_s
    out << content unless content.empty?
    tags = Array(args[:tags]).compact
    out << "\e[2mTags\e[0m   #{tags.join(', ')}" unless tags.empty?
    links = Array(args[:links]).compact
    out << "\e[2mLinks\e[0m  #{links.join(', ')}" unless links.empty?
    out
  end

  def patch_file_body(el, max_lines:)
    result = el[:result]
    return [palette.fail(result[:error])] if result.is_a?(Hash) && result[:error]
    args = el[:args] || {}
    out = []
    path = args[:path].to_s
    out << "\e[1mPfad\e[0m  #{path}" unless path.empty?
    diff = args[:diff].to_s
    n = diff.scan(/<<<<<<< SEARCH/).size
    out << "\e[1m#{n} Edit#{n == 1 ? '' : 's'}\e[0m" if n.positive?
    unless diff.empty?
      out << '' if out.any?
      out << "\e[2m-- diff --\e[0m"
      out.concat cap_lines(diff, max_lines: max_lines)
    end
    out
  end

  def aegis_body(result, max_lines:)
    return [palette.fail(result[:error])] if result.is_a?(Hash) && result[:error]
    return [result.to_s] unless result.is_a?(Hash)
    out = []
    orient = result[:aegis_orientation] || {}
    summary = orient[:summary].to_s
    out << "\e[1mSummary\e[0m  #{summary}" unless summary.empty?
    meta = +''
    meta << "temperature=#{orient[:temperature]}" unless orient[:temperature].nil?
    meta << ' - ' unless meta.empty? || orient[:thinking].nil?
    meta << "thinking=#{orient[:thinking]}" unless orient[:thinking].nil?
    out << "\e[2m#{meta}\e[0m" unless meta.empty?
    notes = result[:aegis_notes] || []
    unless notes.empty?
      out << '' if out.any?
      out << "\e[1mNotizen (#{notes.size})\e[0m"
      notes.first(max_lines || notes.size).each do |note|
        next unless note.is_a?(Hash)
        id = note[:id]
        content = note[:content].to_s
        score = note[:score]
        line = +"#{id ? "\e[1m##{id}\e[0m " : '- '}#{content[0, 120]}"
        line << "  \e[2m[#{score}]\e[0m" if score
        out << line
      end
    end
    out
  end

  def file_overview_body(el, max_lines:)
    result = el[:result]
    return [palette.fail(result[:error])] if result.is_a?(Hash) && result[:error]

    out = []
    fi = result.is_a?(Hash) ? result[:file_info] : nil
    if fi.is_a?(Hash)
      out << palette.accent("@ #{fi[:path]}")
      stats = "#{fi[:lines]} Zeilen · #{fi[:size]} Bytes"
      stats = "#{stats} · #{fi[:last_modified]}" if fi[:last_modified]
      out << palette.dim("  #{stats}")
    end

    section = ->(title, body) do
      body = body.join("\n") if body.is_a?(Array)
      next if body.to_s.strip.empty?

      out << '' if out.any?
      out << palette.accent("── #{title} ──")
      out.concat cap_lines(body.to_s, max_lines: max_lines)
    end

    summary = result.is_a?(Hash) ? result[:structural_summary] : nil
    summary = structural_summary_text(summary) if summary.is_a?(Hash)
    section.call('Struktur', "  #{summary}")

    section.call('Symbole', result.is_a?(Hash) ? result[:symbolic_overview] : nil)
    section.call('Tag-Resonanz', resonance_chips(result.is_a?(Hash) ? result[:tag_cloud] : nil))
    section.call('Datei-Resonanz', resonance_chips(result.is_a?(Hash) ? result[:file_cloud] : nil, limit: 12))

    hermetic = result.is_a?(Hash) ? result[:hermetic_overview] : nil
    hermetic = hermetic.join(', ') if hermetic.is_a?(Array)
    section.call('Hermetik', "  #{hermetic}")

    notes = result.is_a?(Hash) ? Array(result[:notes_preview]) : []
    unless notes.empty?
      body = notes.filter_map do |n|
        next unless n.is_a?(Hash)

        tags = Array(n[:tags]).compact.join(',')
        excerpt = n[:excerpt].to_s.gsub(/\s+/, ' ').strip
        "  ##{n[:id]}#{tags.empty? ? '' : " [#{tags}]"} #{excerpt[0, 90]}"
      end.join("\n")
      section.call("Mnemosyne (#{result[:notes_count]})", body)
    end

    out
  end

  # Collapse a "key: count" resonance block (tag_cloud / file_cloud) into one
  # compact line of `key·count` chips instead of one row per entry.
  def resonance_chips(text, limit: 18)
    pairs = text.to_s.lines.map(&:strip).reject(&:empty?)
    return '' if pairs.empty?

    shown = pairs.first(limit).map { |p| p.sub(/:\s+/, '·') }
    shown << "… +#{pairs.size - limit}" if pairs.size > limit
    "  #{shown.join('  ')}"
  end

  def structural_summary_text(s)
    parts = []
    parts << s[:language].to_s unless s[:language].nil?
    parts << "#{s[:containers]} containers" if s[:containers]
    parts << "#{s[:members]} members" if s[:members]
    parts << "#{s[:imports]} imports" if s[:imports]
    parts << "#{s[:exports]} exports" if s[:exports]
    parts << "#{s[:total_symbols]} symbols" if s[:total_symbols]
    parts.join(' · ')
  end

  def generic_instrumentum_body(result, max_lines:)
    text = result.is_a?(Hash) ? (result[:result] || result.inspect) : result.to_s
    return ['(leer)'] if text.to_s.strip.empty?
    cap_lines(text.to_s, max_lines: max_lines)
  end

  def cap_lines(text, max_lines:)
    lines = text.lines.map(&:chomp)
    return lines if max_lines.nil? || lines.size <= max_lines
    lines.first(max_lines) +
      [ "\e[2m... #{lines.size - max_lines} weitere Zeilen (-> für Vollansicht, Enter öffnet)\e[0m" ]
  end
end