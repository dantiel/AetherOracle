# frozen_string_literal: true

require 'pathname'
require_relative '../argonaut/argonaut'
require_relative '../mnemosyne/mnemosyne'
require_relative '../instrumentarium/symbolic_patch_file'

# ── Toolbelt — the developer's CLI mirror of the oracle's instruments. ─────
# Every command here is a thin terminal front-end over the same primitives the
# agent itself drives (Argonaut for file I/O, Mnemosyne for memory, the
# SealLedger for Salomo's plans, SymbolicPatchFile for AST search), so
# `aetheroracle read` behaves exactly like the agent's `read_file` — but with
# human-friendly output and no tool telemetry.
module Toolbelt
  module_function

  COMMANDS = {
    'read'    => 'read a file (optional start:end range, --numbers)',
    'inspect' => 'symbolic structural overview of a file',
    'write'   => 'create/overwrite a file (body from stdin or --body "…")',
    'mv'      => 'rename/move a file',
    'files'   => 'list project files (optional glob)',
    'ast'     => 'AST-GREP search for a pattern across files',
    'notes'   => 'recall Mnemosyne notes by fuzzy query',
    'note'    => 'add / show / edit / remove a Mnemosyne note',
    'history' => 'show recent chronicle history (--notes for notes)',
    'search'  => 'search Mnemosyne notes + chronicle (--limit N)',
    'aegis'   => 'view / edit Aegis state (summary, tags, temp, thinking, dir)',
    'seal'    => "list / status / delegate Salomo's executive seals"
  }.freeze

  def run(command, args)
    case command
    when 'read', 'cat'          then read(args)
    when 'inspect', 'ov'        then inspect(args)
    when 'write', 'new'         then write(args)
    when 'mv', 'rename'         then rename(args)
    when 'files'                then files(args)
    when 'ast', 'grep'          then ast(args)
    when 'notes', 'mem'         then notes(args)
    when 'note'                 then note(args)
    when 'history', 'hist'      then history(args)
    when 'search', 'find'       then search(args)
    when 'aegis'                then aegis(args)
    when 'seal', 'seals'        then seal(args)
    else usage
    end
  end

  def usage
    puts 'Toolbelt — the developer CLI mirror of the oracle instruments:'
    COMMANDS.each { |name, desc| puts "  #{name.ljust(9)} #{desc}" }
    puts
    puts '  ask <prompt>  one-shot oracle turn (see `aetheroracle help`)'
  end

  # Normalize a user path to a project-relative path (the agent's convention).
  # Handles Unix `/abs` and Windows `C:\…` / `C:/…` absolute forms.
  def rel(path)
    path = path.to_s
    return path if path.empty?
    return path unless path.start_with?('/') || path.match?(/\A[A-Za-z]:[\\\/]/)

    Pathname.new(path).relative_path_from(Pathname.new(Argonaut.project_root)).to_s
  rescue ArgumentError
    path
  end

  def read(args)
    path = args.shift
    abort 'Usage: aetheroracle read <path> [start:end] [--numbers]' if path.nil?

    numbers = false
    range = nil
    args.each do |a|
      case a
      when '--numbers', '-n' then numbers = true
      else
        if (m = a.match(/\A(\d+):(\d+)\z/))
          range = [m[1].to_i, m[2].to_i]
        end
      end
    end

    result = Argonaut.read(rel(path), range, line_numbers: numbers)
    abort result[:error] if result[:error]

    puts result[:content]
  end

  def inspect(args)
    path = args.shift
    abort 'Usage: aetheroracle inspect <path>' if path.nil?

    ov = Argonaut.file_overview(path: rel(path))
    abort ov[:error].to_s if ov[:error]

    fi = ov[:file_info]
    sym = ov[:symbolic_overview]

    cyan = "\e[1;36m"
    dim  = "\e[2m"
    bold = "\e[1m"
    reset = "\e[0m"

    puts "#{cyan}@ #{fi[:path]}#{reset}"
    stats = "#{fi[:lines]} Zeilen · #{fi[:size]} Bytes"
    stats = "#{stats} · #{fi[:last_modified]}" if fi[:last_modified]
    puts "  #{dim}#{stats}#{reset}"

    if sym.nil?
      puts "  #{dim}(keine Strukturinformation)#{reset}"
      return
    end

    if sym.is_a?(Hash) && sym[:error]
      puts sym[:error]
      return
    end

    section = ->(title, body) do
      next if body.to_s.strip.empty?

      puts
      puts "#{cyan}── #{bold}#{title}#{reset}#{cyan} ──#{reset}"
      puts body
    end

    sum = sym[:structural_summary]
    if sum.is_a?(Hash)
      sum = [sum[:language],
             sum[:containers] && "#{sum[:containers]} containers",
             sum[:members] && "#{sum[:members]} members",
             sum[:imports] && "#{sum[:imports]} imports",
             sum[:exports] && "#{sum[:exports]} exports",
             sum[:total_symbols] && "#{sum[:total_symbols]} symbols"].compact.join(' · ')
    end
    section.call('Struktur', "  #{sum}")

    section.call('Symbole', sym[:symbolic_overview_text])
    section.call('Tag-Resonanz', chips(sym[:tag_cloud_text]))
    section.call('Datei-Resonanz', chips(sym[:file_cloud_text], limit: 12))

    hermetic = ov[:hermetic_overview]
    hermetic = hermetic.join(', ') if hermetic.is_a?(Array)
    section.call('Hermetik', "  #{hermetic}")

    return unless ov[:notes_count].to_i.positive?

    notes = Array(ov[:notes_preview]).map do |n|
      next unless n.is_a?(Hash)

      tags = Array(n[:tags]).join(',')
      "  ##{n[:id]}#{tags.empty? ? '' : " [#{tags}]"} #{n[:excerpt].to_s[0, 90]}"
    end.compact
    section.call("Mnemosyne (#{ov[:notes_count]})", notes.join("\n"))
  end

  # Collapse a "key: count" resonance block (tag_cloud_text / file_cloud_text)
  # into one compact line of `key·count` chips instead of one row per entry.
  def chips(text, limit: 18)
    pairs = text.to_s.lines.map(&:strip).reject(&:empty?)
    return '' if pairs.empty?

    shown = pairs.first(limit).map { |p| p.sub(/:\s+/, '·') }
    shown << "… +#{pairs.size - limit}" if pairs.size > limit
    "  #{shown.join('  ')}"
  end

  def write(args)
    path = args.shift
    abort 'Usage: aetheroracle write <path> [--body "text"]  (or pipe the body)' if path.nil?

    body = nil
    expect_body = false
    args.each do |a|
      if expect_body
        body = a
        expect_body = false
      elsif a == '--body' || a == '-b'
        expect_body = true
      end
    end

    body ||= $stdin.read unless $stdin.tty?
    abort 'No content given — pass --body "…" or pipe it in' if body.nil? || body.empty?

    target = rel(path)
    Argonaut.write(target, body)
    puts "wrote #{File.join(Argonaut.project_root, target)} (#{body.bytesize} bytes)"
  end

  def rename(args)
    from = args.shift
    to = args.shift
    abort 'Usage: aetheroracle mv <from> <to>' if from.nil? || to.nil?

    Argonaut.rename(rel(from), rel(to))
    puts "#{from} → #{to}"
  end

  def files(args)
    glob = args.shift
    list = glob ? Argonaut.list_files(glob) : Argonaut.list_project_files
    # list_project_files matches `**/*` (directories included) — a file lister
    # should show files, not directories.
    list = Array(list).reject { |f| File.directory?(File.join(Argonaut.project_root, f)) }
    puts list.join("\n")
  end

  def ast(args)
    pattern = args.shift
    abort 'Usage: aetheroracle ast <pattern> [path-or-glob]' if pattern.nil?
    path = args.shift || '**/*.rb'

    result = SymbolicPatchFile.search(path, pattern)
    abort result[:error] if result[:error]

    matches = result[:matches] || []
    if matches.empty?
      puts 'no matches'
      return
    end

    matches.each { |m| puts "#{m[:file]}:#{m[:line]}:#{m[:column]}  #{m[:text]}" }
    puts "#{matches.size} match#{'es' if matches.size != 1}"
  end

  def notes(args)
    query = args.join(' ').strip
    limit = 10

    # `recall_notes` is fuzzy-scored and, with an empty query, yields the most
    # recent notes — `search` returns nothing for an empty query.
    list = Mnemosyne.recall_notes(query, limit: limit)

    if list.nil? || list.empty?
      puts query.empty? ? 'no notes yet' : "no notes match: #{query}"
      return
    end

    list.each do |n|
      puts "##{n[:id]}  [#{Array(n[:tags]).join(',')}]"
      puts n[:content].to_s
      puts
    end
  end

  def note(args)
    action = args.shift || 'add'
    case action
    when 'add', 'remember', 'new'
      content = args.join(' ').strip
      content = $stdin.read.strip if content.empty? && !$stdin.tty?
      abort 'Usage: aetheroracle note add <content>  (or pipe)' if content.empty?

      id = Mnemosyne.remember(content: content)
      puts "stored note ##{id}"
    when 'show', 'get'
      id = args.shift
      abort 'Usage: aetheroracle note show <id>' if id.nil?

      n = Mnemosyne.get_note(id.to_i)
      abort "no note ##{id}" if n.nil?
      puts "##{n[:id]}  [#{Array(n[:tags]).join(',')}]  links=#{n[:links]}"
      puts n[:content]
    when 'edit', 'update'
      id = args.shift
      abort 'Usage: aetheroracle note edit <id> [--content "…"] [--tags a,b] [--links x,y]' if id.nil?

      updates = {}
      expect = nil
      args.each do |a|
        if expect
          updates[expect] = a
          expect = nil
        elsif a == '--content' || a == '-c' then expect = :content
        elsif a == '--tags'   || a == '-t' then expect = :tags
        elsif a == '--links'  || a == '-l' then expect = :links
        end
      end
      abort 'nothing to update — pass --content/--tags/--links' if updates.empty?

      opts = {}
      opts[:content] = updates[:content] if updates[:content]
      opts[:tags] = updates[:tags].split(',') if updates[:tags]
      opts[:links] = updates[:links].split(',') if updates[:links]
      Mnemosyne.update_note(id.to_i, **opts)
      puts "updated note ##{id}"
    when 'rm', 'remove', 'delete'
      id = args.shift
      abort 'Usage: aetheroracle note rm <id>' if id.nil?

      Mnemosyne.remove_note(id.to_i)
      puts "removed note ##{id}"
    else
      abort "unknown note action: #{action} (add | show | edit | rm)"
    end
  end

  def history(args)
    limit = 7
    notes_mode = false
    args.each do |a|
      case a
      when '--notes', '-n' then notes_mode = true
      when /\A\d+\z/ then limit = a.to_i
      end
    end

    if notes_mode
      list = Mnemosyne.recall_notes('', limit: limit)
      if list.nil? || list.empty?
        puts 'no notes yet'
      else
        list.each { |n| puts "##{n[:id]}  [#{Array(n[:tags]).join(',')}]"; puts n[:content].to_s; puts }
      end
      return
    end

    entries = Mnemosyne.fetch_history(limit: limit)
    if entries.nil? || entries.empty?
      puts 'no history yet'
      return
    end

    entries.each do |e|
      when_str = e[:created_at] || e[:timestamp]
      puts "── #{when_str}  (#{e[:tool_call_count].to_i} tools)"
      puts "❯ #{e[:prompt].to_s.strip}"
      ans = e[:answer].to_s.strip
      puts ans.empty? ? '   (no answer)' : ans
      puts
    end
  end

  def search(args)
    limit = 5
    query = []
    i = 0
    while i < args.length
      a = args[i]
      if a == '--limit' || a == '-n'
        limit = (args[i + 1] || '5').to_i
        i += 2
      elsif (m = a.match(/\A--limit=(\d+)\z/))
        limit = m[1].to_i
        i += 1
      else
        query << a
        i += 1
      end
    end
    q = query.join(' ').strip
    abort 'Usage: aetheroracle search <query> [--limit N]' if q.empty?

    notes = Mnemosyne.recall_notes(q, limit: limit) || []
    entries = Mnemosyne.search(q, limit: limit) || []

    if notes.empty? && entries.empty?
      puts "no match: #{q}"
      return
    end

    unless notes.empty?
      puts "── notes (#{notes.size}) ──"
      notes.each { |n| puts "  ##{n[:id]}  [#{Array(n[:tags]).join(',')}]  #{n[:content].to_s[0, 110]}" }
      puts
    end
    unless entries.empty?
      puts "── history (#{entries.size}) ──"
      entries.each { |e| puts "  ❯ #{e[:prompt].to_s[0, 110]}" }
    end
  end

  # ── Aegis — view/edit the oracle's persistent orientation state. ─────────
  def aegis(args)
    action = args.shift
    case action
    when nil, 'show', 'status', 'view' then aegis_show
    when 'summary', 'sum'                then aegis_set_summary(args.join(' '))
    when 'tags', 'tag'                   then aegis_set_tags(args.join(','))
    when 'temp', 'temperature'           then aegis_set_temperature(args.shift)
    when 'think', 'thinking'             then aegis_set_thinking(args.shift)
    when 'dir', 'workdir', 'working-dir' then aegis_set_dir(args.join(' '))
    when 'undir', 'clear-dir', 'unset-dir' then aegis_set_dir(nil)
    else
      abort "unknown aegis action: #{action} (show | summary | tags | temp | thinking | dir)"
    end
  end

  def aegis_state
    Mnemosyne.restore_aegis
    Mnemosyne.aegis
  end

  def aegis_tags(a)
    t = a[:tags]
    t = t.split(',') if t.is_a?(String)
    Array(t)
  end

  def aegis_show
    a = aegis_state
    puts '── Aegis ──'
    puts "tags:        #{aegis_tags(a).join(', ')}"
    puts "summary:     #{a[:summary].to_s}"
    puts "temperature: #{a[:temperature]}"
    puts "thinking:    #{a[:thinking] || '-'}"
    puts "working_dir: #{a[:working_dir] || '-'}"
  end

  def aegis_set_summary(text)
    abort 'usage: aetheroracle aegis summary <text>' if text.to_s.strip.empty?
    aegis_state
    Mnemosyne.update_aegis_summary(text)
    aegis_show
  end

  def aegis_set_tags(raw)
    tags = raw.split(',').map(&:strip).reject(&:empty?)
    abort 'usage: aetheroracle aegis tags a,b,c' if tags.empty?
    state = aegis_state
    state[:tags] = tags
    Mnemosyne.save_aegis_state(**state)
    aegis_show
  end

  def aegis_set_temperature(raw)
    abort 'usage: aetheroracle aegis temp <0.0..2.0>' if raw.nil?
    value = Float(raw)
    abort "temperature out of range: #{value}" unless value.between?(0.0, 2.0)
    aegis_state
    Mnemosyne.set_aegis_temperature(value)
    aegis_show
  rescue ArgumentError
    abort "invalid temperature: #{raw}"
  end

  def aegis_set_thinking(raw)
    abort 'usage: aetheroracle aegis think <fast|normal|high|max>' if raw.nil?
    level = raw.to_s.downcase
    abort "invalid thinking: #{raw} (fast|normal|high|max)" unless %w[fast normal high max].include?(level)
    aegis_state
    Mnemosyne.set_aegis_thinking(level)
    aegis_show
  end

  def aegis_set_dir(dir)
    state = aegis_state
    state[:working_dir] = (dir.nil? || dir.empty?) ? nil : dir
    Mnemosyne.save_aegis_state(**state)
    aegis_show
  end

  def seal(args)
    action = args.shift || 'list'
    case action
    when 'list', 'ls'
      seals = Array(Mnemosyne::SealLedger.list_seals)
      if seals.empty?
        puts 'no seals'
      else
        seals.each do |s|
          puts "##{s[:id]}  [#{s[:status] || '?'}]  #{s[:goal]}"
          puts "   #{s[:description]}" if s[:description] && !s[:description].to_s.empty?
        end
      end
    when 'status', 'show'
      id = args.shift
      abort 'Usage: aetheroracle seal status <id>' if id.nil?
      print_seal_status(id.to_i)
    when 'delegate'
      task_id = args.shift
      owner = args.shift
      abort 'Usage: aetheroracle seal delegate <task_id> <owner>' if task_id.nil? || owner.nil?
      Mnemosyne::SealLedger.delegate(task_id.to_i, owner)
      puts "delegated task ##{task_id} → #{owner}"
    else
      abort "unknown seal action: #{action} (list | status <id> | delegate <task_id> <owner>)"
    end
  end

  def print_seal_status(id)
    status = Mnemosyne::SealLedger.seal_status(id)
    abort status[:error].to_s if status[:error]

    seal = status[:seal]
    puts "##{seal[:id]}  [#{seal[:status]}]  #{seal[:goal]}"
    progress = status[:progress] || {}
    puts "progress: #{progress[:completed]}/#{progress[:total]} (#{progress[:ratio]})"

    status[:milestones].to_a.each do |m|
      mark = status[:next] && status[:next][:id] == m[:id] ? '▶' : ' '
      owner = m[:owner].to_s.empty? ? '-' : m[:owner]
      deps = Array(m[:depends_on]).empty? ? '' : "  deps=#{m[:depends_on].inspect}"
      puts "  #{mark} ##{m[:id]} [#{m[:status]}] (#{owner}) #{m[:title]}#{deps}"
    end
  end
end