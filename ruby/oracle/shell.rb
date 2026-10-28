# frozen_string_literal: true

require 'json'
require 'csv'
require 'yaml'
require 'fileutils'
require 'open3'
require 'shellwords'

# ÆtherShell — the polymorphic shell of PythiaCLI.
#
# Summoned when the practitioner types `$` at the start of the prompt: the
# chamber's cyan `π` transmorphs into a green `$`, and the room becomes a
# structured-data shell in the spirit of Nushell. Commands are *filters* over
# rows of records — `ls | where type == dir | sort-by size` — rather than
# byte-stream text tools, yet any external program still passes straight
# through to the operating system. Builtins cover the common ground; the rest
# is delegated. It is a full shell replacement, not a toy.
#
#   $ ls
#   $ ls | where type == file | sort-by size | take 5
#   $ git status
#   $ open docs/aetherverse.html | grep oracle
#
# Type `exit` (or Ctrl-D) to return to the oracle.
class ÆtherShell
  WINDOWS = !!(RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i)

  begin
    require 'readline'
    HAVE_READLINE = true
  rescue LoadError
    HAVE_READLINE = false
  end

  ANSI_RE = /\e\[[0-9;?]*[@-~]|\e\][^\a]*(?:\a|\e\\)|\e[@-~]/

  BUILTIN_METHODS = {
    'ls' => :cmd_ls, 'dir' => :cmd_ls, 'cd' => :cmd_cd, 'pwd' => :cmd_pwd,
    'cat' => :cmd_cat, 'type' => :cmd_cat, 'open' => :cmd_open,
    'head' => :cmd_head, 'tail' => :cmd_tail, 'first' => :cmd_first,
    'last' => :cmd_last, 'lines' => :cmd_lines, 'wc' => :cmd_wc,
    'grep' => :cmd_grep, 'find' => :cmd_find, 'where' => :cmd_where,
    'sort-by' => :cmd_sort_by, 'take' => :cmd_take, 'skip' => :cmd_skip,
    'select' => :cmd_select, 'get' => :cmd_get, 'columns' => :cmd_columns,
    'unique' => :cmd_unique, 'length' => :cmd_length, 'count' => :cmd_length,
    'group-by' => :cmd_group_by, 'append' => :cmd_append, 'prepend' => :cmd_prepend,
    'each' => :cmd_each, 'echo' => :cmd_echo, 'mkdir' => :cmd_mkdir,
    'touch' => :cmd_touch, 'rm' => :cmd_rm, 'del' => :cmd_rm, 'rmdir' => :cmd_rm,
    'cp' => :cmd_cp, 'copy' => :cmd_cp, 'mv' => :cmd_mv, 'move' => :cmd_mv,
    'env' => :cmd_env, 'set' => :cmd_set, 'date' => :cmd_date, 'which' => :cmd_which,
    'history' => :cmd_history, 'help' => :cmd_help, 'clear' => :cmd_clear, 'cls' => :cmd_clear,
    'to' => :cmd_to, 'from' => :cmd_from, 'save' => :cmd_save,
    'str' => :cmd_str
  }.freeze

  BUILTIN_HELP = {
    'ls [path] [-a]' => 'list a directory as records (name/type/size/modified)',
    'cd [path]' => 'change directory ("" = home, `-` = previous)',
    'pwd' => 'print the working directory',
    'cat <files…>' => 'concatenate files into a string',
    'open <file>' => 'read a file; parses .json/.csv/.yaml, else raw text',
    'head/tail [n]' => 'first/last n rows',
    'lines' => 'split a string into line rows',
    'wc [-l] [files…]' => 'count lines/words/bytes',
    'grep <pattern> [files…]' => 'filter lines matching a regex',
    'find [path] [pattern]' => 'recursive file listing',
    'where <col> <op> <value>' => 'filter rows (== != > < >= <= =~ contains)',
    'sort-by <col> [desc|asc]' => 'sort rows by a column',
    'take/skip <n>' => 'take or drop the first n rows',
    'select <col…>' => 'project specific columns',
    'get <col.path>' => 'extract a column as scalar values',
    'columns' => 'list the column names',
    'unique' => 'remove duplicate rows',
    'length' => 'number of rows (count)',
    'group-by <col>' => 'group rows into a record keyed by column value',
    'append/prepend <value>' => 'add a row/value to the stream',
    'each <cmd>' => 'run a command per row ($it refers to the row)',
    'echo <args…>' => 'print a string',
    'mkdir/touch/rm/cp/mv' => 'filesystem operations',
    'env' => 'list environment variables as records',
    'set <name> <value>' => 'set an environment variable',
    'date [format]' => 'current date/time',
    'which <cmd>' => 'locate an executable',
    'history' => 'this session\'s command history',
    'to json|csv|yaml' => 'serialize rows',
    'from json|csv|yaml' => 'parse a string into rows',
    'save <file>' => 'write output to a file',
    'str upcase|downcase|trim' => 'transform string rows',
    'help' => 'this listing', 'clear' => 'clear the screen',
    'exit' => 'return to the oracle'
  }.freeze

  COMPARATORS = {
    '==' => ->(a, b) { a == b }, '!=' => ->(a, b) { a != b },
    '>' => ->(a, b) { a.to_f > b.to_f }, '<' => ->(a, b) { a.to_f < b.to_f },
    '>=' => ->(a, b) { a.to_f >= b.to_f }, '<=' => ->(a, b) { a.to_f <= b.to_f },
    '=~' => ->(a, b) { a.to_s.match?(Regexp.new(b.to_s)) },
    'contains' => ->(a, b) { a.to_s.include?(b.to_s) },
    'starts-with' => ->(a, b) { a.to_s.start_with?(b.to_s) }
  }.freeze

  attr_accessor :current_row

  def initialize(palette: nil)
    @palette = palette
    @cwd = Dir.pwd
    @previous_cwd = nil
    @vars = {}
    @history = []
    @last_exit = 0
    @running = false
    @current_row = nil
    @defer_it = true
    @capture_mode = false
  end

  # ----------------------------------------------------------------- run --

  # Run the shell REPL. When `initial_input` is given it is executed once
  # before the loop (the `$ ls` one-shot form), then the loop takes over.
  def run(initial_input = nil)
    @running = true
    execute(initial_input) if initial_input && !initial_input.strip.empty?
    while @running
      line = read_line
      break if line.nil?
      line = line.strip
      next if line.empty?
      if %w[exit quit logout].include?(line)
        @running = false
        break
      end
      @history << line
      execute(line)
    end
  ensure
    @running = false
  end

  # ------------------------------------------------------------- pipeline --

  def execute(line)
    return if line.nil? || line.strip.empty?

    rows = eval_chain(line)
    render(rows) unless rows.nil? || rows == :halt
    rows
  rescue StandardError => e
    $stderr.puts "\e[31mshell: #{e.class}: #{e.message}\e[0m"
    @last_exit = 1
    nil
  end

  # Evaluate a command line with `;`, `&&`, `||` short-circuiting. Returns the
  # final rows (Array of records/strings), or :halt when `exit` was issued.
  def eval_chain(line)
    if (m = /\A\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/m.match(line))
      @vars[m[1].to_sym] = expand_value(m[2])
      @last_exit = 0
      return []
    elsif (m = /\A\s*\$env\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/m.match(line))
      ENV[m[1]] = expand_value(m[2]).to_s
      @last_exit = 0
      return []
    end

    tokens = tokenize(line)
    stmts = split_statements(tokens)
    result = []
    stmts.each_with_index do |(op, toks), idx|
      if idx.positive?
        case op
        when '&&' then next unless @last_exit.zero?
        when '||' then next if @last_exit.zero?
        end
      end
      result = eval_pipeline(toks)
      return :halt if result == :halt
    end
    result
  end

  def eval_pipeline(toks)
    segments = split_on_pipe(toks)
    redirect = { in: nil, out: nil, append: false }
    argv_list = []
    segments.each do |seg|
      argv, redir = build_argv(seg)
      argv_list << [argv, redir]
      redirect[:in] ||= redir[:in]
      redirect[:out] ||= redir[:out]
      redirect[:append] = true if redir[:append]
    end

    # A lone external command inherits the terminal (interactive pagers/editors).
    argv, redir = argv_list.first
    if argv_list.length == 1 && !builtin?(argv[0]) && redirect[:out].nil? && redirect[:in].nil? && !@capture_mode
      return run_interactive_external(argv)
    end

    rows = nil
    argv_list.each do |av, rd|
      rows = run_segment(av, rd, rows)
      return :halt if rows == :halt
    end

    if redirect[:out]
      write_file(redirect[:out], format_rows(rows), append: redirect[:append])
      rows = []
    end
    rows
  end

  def run_segment(argv, redir, input_rows)
    return [] if argv.empty?

    name = argv[0]
    args = argv[1..]
    if builtin?(name)
      rows = dispatch_builtin(name, args, input_rows)
      @last_exit = rows == :halt ? 0 : 0
      rows
    else
      rows, err, status = run_external(argv, redir)
      $stderr.write(err) if err && !err.empty?
      @last_exit = status
      rows
    end
  end

  def run_interactive_external(argv)
    system(*argv, chdir: @cwd)
    @last_exit = $?.exitstatus || 0
    []
  end

  def run_external(argv, redir)
    stdin_data = redir[:in] ? File.read(resolve(redir[:in])) : ''
    out, err, status = Open3.capture3(*argv, stdin_data: stdin_data, chdir: @cwd)
    lines = out.split("\n", -1)
    lines.pop if lines.last == ''
    [lines.map(&:rstrip), err, status.exitstatus.to_i]
  rescue Errno::ENOENT, Errno::EACCES => e
    [[], "#{argv[0]}: #{e.message}", 127]
  rescue StandardError => e
    [[], "#{e.message}", 1]
  end

  # ------------------------------------------------------------ tokenizer --

  def tokenize(str)
    tokens = []
    i = 0
    while i < str.length
      c = str[i]
      case c
      when /\s/ then i += 1
      when '|'
        if str[i + 1] == '|'
          tokens << [:and, '||']; i += 2
        else
          tokens << [:pipe, '|']; i += 1
        end
      when '>'
        if str[i + 1] == '>'
          tokens << [:redirect_append, '>>']; i += 2
        else
          tokens << [:redirect_out, '>']; i += 1
        end
      when '<'
        tokens << [:redirect_in, '<']; i += 1
      when '&'
        tokens << (str[i + 1] == '&' ? [:and, '&&'] : [:word, '&'])
        i += (str[i + 1] == '&' ? 2 : 1)
      when ';'
        tokens << [:semi, ';']; i += 1
      when '"'
        val, i = read_double_quoted(str, i + 1); tokens << [:word, val]
      when "'"
        val, i = read_single_quoted(str, i + 1); tokens << [:word, val]
      else
        val, i = read_bare(str, i); tokens << [:word, val]
      end
    end
    tokens
  end

  def read_bare(str, i)
    out = +''
    while i < str.length
      c = str[i]
      if c =~ /\s/ || %w[| > < & ;].include?(c)
        break
      elsif c == '"'
        v, i2 = read_double_quoted(str, i + 1); out << v; i = i2
      elsif c == "'"
        v, i2 = read_single_quoted(str, i + 1); out << v; i = i2
      elsif c == '\\'
        out << str[i + 1].to_s; i += 2
      elsif c == '$'
        v, i2 = read_var(str, i); out << v; i = i2
      else
        out << c; i += 1
      end
    end
    [out, i]
  end

  def read_double_quoted(str, i)
    out = +''
    while i < str.length
      c = str[i]
      if c == '"'
        return [out, i + 1]
      elsif c == '\\'
        out << str[i + 1].to_s; i += 2
      elsif c == '$'
        v, i2 = read_var(str, i); out << v; i = i2
      else
        out << c; i += 1
      end
    end
    [out, i]
  end

  def read_single_quoted(str, i)
    j = str.index("'", i) || str.length
    [str[i...j], j + 1]
  end

  def read_var(str, i)
    c = str[i + 1]
    if c == '('
      j = i + 2; depth = 1
      while j < str.length && depth.positive?
        depth += 1 if str[j] == '('
        depth -= 1 if str[j] == ')'
        j += 1
      end
      inner = str[(i + 2)...(j - 1)]
      [capture_eval(inner).to_s.sub(/\n\z/, ''), j]
    elsif c == '{'
      j = str.index('}', i + 2) || str.length
      [@vars[str[(i + 2)...j].to_sym].to_s, j + 1]
    elsif c == 'e' && str[i + 1, 4] == 'env.'
      m = /\Aenv\.([A-Za-z_][A-Za-z0-9_]*)/.match(str[(i + 1)..])
      val = ENV[m[1]].to_s
      consumed = 1 + m[0].length
      if str[i + consumed] == '.'
        segs, plen = read_cell_path(str[(i + consumed)..])
        val = resolve_cell(val, segs).to_s
        consumed += plen
      end
      [val, i + consumed]
    else
      m = /\A[A-Za-z_][A-Za-z0-9_]*/.match(str[(i + 1)..])
      unless m
        return ['$', i + 1]
      end

      name = m[0]
      rest = str[(i + 1 + m[0].length)..]
      segs = []
      plen = 0
      if rest&.start_with?('.')
        segs, plen = read_cell_path(rest)
      end

      if name == 'it' && @defer_it
        return [str[i...(i + 1 + m[0].length + plen)], i + 1 + m[0].length + plen]
      end

      val = name == 'it' ? @current_row : @vars[name.to_sym]
      val = resolve_cell(val, segs) unless segs.empty?
      [val.to_s, i + 1 + m[0].length + plen]
    end
  end

  def read_cell_path(str)
    segs = []
    i = 0
    while i < str.length && str[i] == '.'
      i += 1
      m = /\A([A-Za-z_][A-Za-z0-9_]*|\d+)/.match(str[i..])
      break unless m

      segs << (m[1] =~ /\A\d+\z/ ? m[1].to_i : m[1].to_sym)
      i += m[0].length
    end
    [segs, i]
  end

  def resolve_cell(val, segs)
    segs.each do |s|
      val = case val
            when Hash then val[s] || val[s.to_s]
            when Array then val[s]
            else nil
            end
      break if val.nil?
    end
    val
  end

  def capture_eval(line)
    @last_exit = 0
    @capture_mode = true
    rows = eval_chain(line)
    rows == :halt ? '' : format_rows(rows)
  rescue StandardError => e
    $stderr.puts "\e[31mshell: #{e.message}\e[0m"
    ''
  ensure
    @capture_mode = false
  end

  # ---------------------------------------------------------- parsing help --

  def split_on_pipe(toks)
    segs = [[]]
    toks.each do |t|
      if t[0] == :pipe
        segs << []
      else
        segs.last << t
      end
    end
    segs
  end

  def split_statements(toks)
    stmts = []
    cur = []
    cur_op = nil
    toks.each do |t|
      if %i[semi and or].include?(t[0])
        stmts << [cur_op, cur] unless cur.empty?
        cur_op = t[1]
        cur = []
      else
        cur << t
      end
    end
    stmts << [cur_op, cur] unless cur.empty?
    stmts
  end

  def build_argv(seg)
    argv = []
    redir = { in: nil, out: nil, append: false }
    i = 0
    while i < seg.length
      t = seg[i]
      case t[0]
      when :word then argv << t[1]
      when :redirect_out then redir[:out] = seg[i + 1]&.[](1); i += 1
      when :redirect_append then redir[:out] = seg[i + 1]&.[](1); redir[:append] = true; i += 1
      when :redirect_in then redir[:in] = seg[i + 1]&.[](1); i += 1
      end
      i += 1
    end
    [argv, redir]
  end

  def builtin?(name)
    name && (BUILTIN_METHODS.key?(name) || name == 'exit' || name == 'quit')
  end

  def dispatch_builtin(name, args, rows)
    return :halt if %w[exit quit logout].include?(name)

    send(BUILTIN_METHODS[name], args, rows)
  end

  # ------------------------------------------------------------ builtins --

  def cmd_ls(args, rows)
    path = args.find { |a| !a.start_with?('-') } || '.'
    all = args.include?('-a') || args.include?('--all')
    dir = resolve(path)
    entries = begin
      Dir.children(dir)
    rescue StandardError
      $stderr.puts "shell: ls: no such directory: #{path}"
      return []
    end
    entries += ['.', '..'] if all
    entries.sort!
    entries.map do |name|
      full = File.join(dir, name)
      st = begin
        File.lstat(full)
      rescue StandardError
        nil
      end
      { 'name' => name,
        'type' => (File.directory?(full) ? 'dir' : File.symlink?(full) ? 'link' : 'file'),
        'size' => (st && st.file? ? st.size : nil),
        'modified' => (st ? st.mtime.strftime('%Y-%m-%d %H:%M') : '') }
    end
  end

  def cmd_cd(args, rows)
    target = args.first
    if target.nil? || target.empty? || target == '~'
      target = Dir.home
    elsif target == '-'
      target = @previous_cwd || @cwd
    end
    newdir = resolve(target)
    unless File.directory?(newdir)
      $stderr.puts "shell: cd: no such directory: #{target}"
      @last_exit = 1
      return rows
    end
    @previous_cwd = @cwd
    @cwd = newdir
    @last_exit = 0
    rows
  end

  def cmd_pwd(args, rows)
    [@cwd]
  end

  def cmd_cat(args, rows)
    [args.flat_map { |a| expand_glob(a) }.map { |f| File.read(resolve(f)) rescue '' }.join]
  end

  def cmd_open(args, rows)
    return [] if args.empty?

    path = resolve(expand_glob(args.first).first || args.first)
    content = File.read(path)
    case File.extname(path).downcase
    when '.json' then parse_rows(content, :json)
    when '.csv' then parse_rows(content, :csv)
    when '.yaml', '.yml' then parse_rows(content, :yaml)
    else [content]
    end
  rescue StandardError => e
    $stderr.puts "shell: open: #{e.message}"
    []
  end

  def cmd_head(args, rows)
    n = (args.find { |a| a =~ /\A\d+\z/ } || 10).to_i
    rows.first(n)
  end

  def cmd_tail(args, rows)
    n = (args.find { |a| a =~ /\A\d+\z/ } || 10).to_i
    rows.last(n)
  end

  def cmd_first(args, rows)
    [rows.first].compact
  end

  def cmd_last(args, rows)
    [rows.last].compact
  end

  def cmd_lines(args, rows)
    rows.flat_map { |r| r.to_s.split("\n") }
  end

  def cmd_wc(args, rows)
    count_lines = args.include?('-l')
    files = args.reject { |a| a.start_with?('-') }
    text = if files.empty?
             rows.map(&:to_s).join("\n")
           else
             files.flat_map { |f| expand_glob(f) }.map { |f| File.read(resolve(f)) rescue '' }.join
           end
    lines = text.count("\n")
    words = text.split.length
    bytes = text.bytesize
    [count_lines ? lines.to_s : "#{lines} #{words} #{bytes}"]
  end

  def cmd_grep(args, rows)
    return [] if args.empty?

    pattern = Regexp.new(args.first)
    files = args[1..]
    text = if files.empty?
             rows.map(&:to_s).join("\n")
           else
             files.flat_map { |f| expand_glob(f) }.map { |f| File.read(resolve(f)) rescue '' }.join("\n")
           end
    text.lines(chomp: true).select { |l| l.match?(pattern) }
  rescue RegexpError => e
    $stderr.puts "shell: grep: #{e.message}"
    []
  end

  def cmd_find(args, rows)
    path = args[0] || '.'
    pattern = args[1]
    dir = resolve(path)
    Dir.glob(File.join(dir, '**', '*')).select do |f|
      pattern.nil? || File.basename(f).match?(Regexp.new(pattern))
    rescue RegexpError
      true
    end.map do |f|
      { 'path' => f, 'type' => (File.directory?(f) ? 'dir' : 'file'),
        'size' => (File.file?(f) ? File.size(f) : nil) }
    end
  end

  def cmd_where(args, rows)
    return rows unless rows.all? { |r| r.is_a?(Hash) }

    col = args[0]
    if args.length == 1
      return rows.select { |r| truthy?(resolve_cell(r, cell_segments(col))) }
    end

    op = args[1]
    cmp = COMPARATORS[op]
    return rows unless cmp

    raw = args[2]
    val = coerce_compare(raw)
    rows.select { |r| cmp.call(resolve_cell(r, cell_segments(col)), val) }
  end

  def cmd_sort_by(args, rows)
    return rows if args.empty?

    col = args[0]
    dir = args[1] == 'desc' ? -1 : 1
    segs = cell_segments(col)
    keys = rows.map { |r| resolve_cell(r, segs) }
    numeric = keys.all? { |v| v.is_a?(Numeric) || (v.is_a?(String) && v =~ /\A-?\d+(\.\d+)?\z/) }
    sorted = rows.zip(keys).sort_by do |_, v|
      if numeric
        v.is_a?(Numeric) ? v : v.to_f
      else
        v.is_a?(String) ? v.downcase : v.to_s
      end
    end.map(&:first)
    dir.negative? ? sorted.reverse : sorted
  end

  def cmd_take(args, rows)
    n = (args.first || 0).to_i
    rows.first(n)
  end

  def cmd_skip(args, rows)
    n = (args.first || 0).to_i
    rows.drop(n)
  end

  def cmd_select(args, rows)
    return rows unless rows.all? { |r| r.is_a?(Hash) }

    keys = args.map { |a| a.split('.').first }
    rows.map { |r| r.slice(*keys) }
  end

  def cmd_get(args, rows)
    return [] if args.empty?

    segs = cell_segments(args.first)
    rows.map { |r| resolve_cell(r, segs) }
  end

  def cmd_columns(args, rows)
    return [] unless rows.all? { |r| r.is_a?(Hash) }

    rows.first.keys
  end

  def cmd_unique(args, rows)
    rows.uniq
  end

  def cmd_length(args, rows)
    [rows.length]
  end

  def cmd_group_by(args, rows)
    return {} if args.empty?

    col = args.first
    rows.group_by { |r| resolve_cell(r, cell_segments(col)).to_s }
  end

  def cmd_append(args, rows)
    rows + [coerce_scalar(args.join(' '))]
  end

  def cmd_prepend(args, rows)
    [coerce_scalar(args.join(' '))] + rows
  end

  def cmd_each(args, rows)
    return [] if args.empty? || rows.empty?

    sub = args.map { |a| dquote(a) }.join(' ')
    saved_row = @current_row
    saved_defer = @defer_it
    @defer_it = false
    out = []
    rows.each do |r|
      @current_row = r
      res = eval_chain(sub)
      out.concat(Array(res)) unless res == :halt
    end
    @current_row = saved_row
    @defer_it = saved_defer
    out
  end

  def cmd_echo(args, rows)
    [args.join(' ')]
  end

  def cmd_mkdir(args, rows)
    args.each { |a| FileUtils.mkdir_p(resolve(a)) }
    []
  end

  def cmd_touch(args, rows)
    args.flat_map { |a| expand_glob(a) }.each { |a| FileUtils.touch(resolve(a)) }
    []
  end

  def cmd_rm(args, rows)
    args.flat_map { |a| expand_glob(a) }.each do |a|
      p = resolve(a)
      File.directory?(p) ? FileUtils.rm_rf(p) : FileUtils.rm_f(p)
    end
    []
  end

  def cmd_cp(args, rows)
    return [] if args.length < 2

    *srcs, dst = args
    FileUtils.cp_r(srcs.flat_map { |a| expand_glob(a) }.map { |a| resolve(a) }, resolve(dst))
    []
  rescue StandardError => e
    $stderr.puts "shell: cp: #{e.message}"
    []
  end

  def cmd_mv(args, rows)
    return [] if args.length < 2

    *srcs, dst = args
    FileUtils.mv(srcs.flat_map { |a| expand_glob(a) }.map { |a| resolve(a) }, resolve(dst))
    []
  rescue StandardError => e
    $stderr.puts "shell: mv: #{e.message}"
    []
  end

  def cmd_env(args, rows)
    ENV.sort.map { |k, v| { 'name' => k, 'value' => v } }
  end

  def cmd_set(args, rows)
    return cmd_env(args, rows) if args.empty?

    ENV[args[0]] = args[1..].join(' ')
    []
  end

  def cmd_date(args, rows)
    fmt = args.first
    fmt ? [Time.now.strftime(fmt)] : [Time.now.strftime('%Y-%m-%d %H:%M:%S')]
  end

  def cmd_which(args, rows)
    return [] if args.empty?

    args.map do |a|
      found = ENV['PATH'].to_s.split(File::PATH_SEPARATOR).map { |d| File.join(d, a) }
                         .find { |f| File.executable?(f) }
      { 'command' => a, 'path' => found }
    end
  end

  def cmd_history(args, rows)
    @history.each_with_index.map { |h, i| { 'id' => i + 1, 'command' => h } }
  end

  def cmd_help(args, rows)
    [BUILTIN_HELP.map { |k, v| "#{k.ljust(28)} #{v}" }.join("\n")]
  end

  def cmd_clear(args, rows)
    STDOUT.print "\e[2J\e[H"
    []
  end

  def cmd_to(args, rows)
    fmt = args.first
    case fmt
    when 'json' then [JSON.pretty_generate(rows)]
    when 'csv' then [to_csv(rows)]
    when 'yaml', 'yml' then [rows.to_yaml]
    else [format_rows(rows)]
    end
  end

  def cmd_from(args, rows)
    fmt = args.first
    text = rows.map(&:to_s).join("\n")
    parse_rows(text, fmt.to_sym)
  end

  def cmd_save(args, rows)
    return rows if args.empty?

    File.write(resolve(args.first), format_rows(rows))
    []
  end

  def cmd_str(args, rows)
    op = args.first
    rows.map do |r|
      s = r.to_s
      case op
      when 'upcase' then s.upcase
      when 'downcase' then s.downcase
      when 'trim' then s.strip
      when 'reverse' then s.reverse
      else s
      end
    end
  end

  # ------------------------------------------------------------- helpers --

  def parse_rows(text, fmt)
    case fmt
    when :json
      data = JSON.parse(text)
      data.is_a?(Array) ? data : [data]
    when :csv
      CSV.parse(text, headers: true).map(&:to_h)
    when :yaml
      data = YAML.safe_load(text, permitted_classes: [Time, Date])
      data.is_a?(Array) ? data : [data]
    else
      [text]
    end
  rescue StandardError => e
    $stderr.puts "shell: from #{fmt}: #{e.message}"
    [text]
  end

  def to_csv(rows)
    return '' unless rows.all? { |r| r.is_a?(Hash) }

    headers = rows.flat_map(&:keys).uniq
    CSV.generate do |csv|
      csv << headers
      rows.each { |r| csv << headers.map { |h| r[h] } }
    end
  end

  def cell_segments(col)
    col.to_s.split('.').map { |s| s =~ /\A\d+\z/ ? s.to_i : s.to_sym }
  end

  # Tokenize + expand the right-hand side of an assignment (`$x = ...`). The
  # `$()`/`$var` expansion happens during tokenization, so a single pass yields
  # the final value; multi-word literals are rejoined into one string.
  def expand_value(str)
    words = tokenize(str).map { |t| t[1] }
    coerce_scalar(words.length == 1 ? words.first : words.join(' '))
  end

  # Quote an argv element for re-tokenization inside `each` so `$it` still
  # expands (double quotes allow variable expansion, single quotes would not).
  def dquote(s)
    '"' + s.gsub(/[\\"]/) { |m| '\\' + m } + '"'
  end

  def coerce_compare(raw)
    return raw.to_f if raw =~ /\A-?\d+(\.\d+)?\z/
    return true if raw == 'true'
    return false if raw == 'false'
    return nil if raw == 'null'

    raw
  end

  def coerce_scalar(s)
    return s.to_i if s =~ /\A-?\d+\z/
    return s.to_f if s =~ /\A-?\d+\.\d+\z/
    return true if s == 'true'
    return false if s == 'false'

    s
  end

  def truthy?(v)
    !v.nil? && v != false && v != '' && v != 0
  end

  def expand_glob(arg)
    return [arg] unless arg =~ /[*?\[\]]/

    Dir.glob(resolve(arg))
  end

  def resolve(path)
    return @cwd if path.nil? || path.empty?

    File.expand_path(path, @cwd)
  end

  def write_file(path, text, append: false)
    File.open(resolve(path), append ? 'a' : 'w') { |f| f.write(text) }
    File.open(resolve(path), 'a') { |f| f.write("\n") } unless text.end_with?("\n")
  rescue StandardError => e
    $stderr.puts "shell: #{e.message}"
  end

  # ------------------------------------------------------------ rendering --

  def render(rows)
    STDOUT.puts format_rows(rows) unless rows.nil? || rows.empty?
  end

  def format_rows(rows)
    return JSON.pretty_generate(rows) if rows.is_a?(Hash)
    return '' if rows.nil?

    rows = [rows] unless rows.is_a?(Array)
    return '' if rows.empty?

    if rows.all? { |r| r.is_a?(Hash) }
      format_table(rows)
    else
      rows.map { |r| scalar_string(r) }.join("\n")
    end
  end

  def scalar_string(r)
    case r
    when nil then ''
    when String then r
    when Hash, Array then JSON.generate(r)
    else r.to_s
    end
  end

  def format_table(rows)
    cols = rows.flat_map(&:keys).uniq.map(&:to_s)
    str_rows = rows.map { |r| cols.map { |c| cell_str(r[c]) } }
    widths = cols.each_with_index.map do |c, i|
      [c.length, *str_rows.map { |sr| vis_len(sr[i]) }].max
    end

    header = cols.each_with_index.map { |c, i| "\e[1;36m#{c.ljust(widths[i])}\e[0m" }.join('  ')
    sep = widths.map { |w| '-' * w }.join('  ')
    body = str_rows.map { |sr| sr.each_with_index.map { |v, i| v.ljust(widths[i]) }.join('  ') }
    ([header, sep] + body).join("\n")
  end

  def cell_str(v)
    case v
    when nil then ''
    when String then v
    when Hash, Array then JSON.generate(v)
    else v.to_s
    end
  end

  def vis_len(s)
    s.gsub(ANSI_RE, '').length
  end

  # -------------------------------------------------------------- prompt --

  def prompt
    home = Dir.home
    cwd = @cwd.sub(/\A#{Regexp.escape(home)}/, '~')
    "\e[1;32m#{cwd}\e[0m \e[1;33m$\e[0m "
  end

  def read_line
    STDOUT.print prompt
    STDOUT.flush
    if HAVE_READLINE && !WINDOWS
      Readline.readline('', true)
    else
      $stdin.gets
    end
  end
end