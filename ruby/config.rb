require 'fileutils'
require 'yaml'
require 'json'
require 'pathname'
require 'dotenv'
require_relative 'instrumentarium/metaprogramming_utils'



# Unified hierarchical configuration loading system.
#
# A context is identified by a config file - `.aethercodex` (YAML) or
# `.aether_properties` (flat `key = value`) - placed at the context root.
# Resolution walks up from the working directory, merging every config it
# finds until it reaches a boundary:
#   * started inside the user home dir  -> stop at the home dir (never crawl above it)
#   * started anywhere else (e.g. another drive) -> crawl to the filesystem root
# Deeper (more specific) configs override shallower (more general) ones; the
# bundle's own config (lowest priority) is always merged underneath.
class CONFIG

  # Recognized config file names, in precedence order. `.aethercodex` (YAML) is
  # authoritative; `.aether_properties` (flat `key = value`) is the lightweight
  # alternative. A directory carries at most one of them as its context marker.
  CONFIG_FILENAMES = ['.aethercodex', '.aether_properties'].freeze
  
  class << self
    
    def load_hierarchical_config(start_dir = Dir.pwd)
      configs = []
      source_dirs = {}
      home = File.expand_path(Dir.home)

      # 1. Bundle's own config (lowest priority, always merged underneath)
      bundle_config_path = config_file_in(__dir__)
      if bundle_config_path
        bundle_config = load_config_file(bundle_config_path)
        bundle_config[:__source] = :bundle
        configs << bundle_config
        source_dirs[:bundle] = File.dirname(bundle_config_path)
      end

      # User preferences and credentials apply to projects on every drive.
      # Load the home config as a low-priority base; project and nearer configs
      # later in the chain can still override it.
      user_config_path = File.join(home, '.aethercodex')
      if File.file?(user_config_path) && !config_chain(start_dir).include?(user_config_path)
        user_config = load_config_file(user_config_path)
        user_config[:__source] = :home
        configs << user_config
        source_dirs[:home] = home
      end

      # 2. The walk-up chain: merge every config from the boundary down to the
      #    start directory. Reverse order (boundary first) so the deepest config
      #    - the one actually identifying the context - wins the merge.
      config_chain(start_dir).reverse_each do |path|
        dir = File.dirname(path)
        project_config = load_config_file(path)
        project_config[:__source] = (dir == home) ? :home : :project
        configs << project_config
        source_dirs[project_config[:__source]] = dir
      end

      # Merge all configs with proper precedence (first = lowest, last = highest)
      merged_config = {}
      configs.each { |config| merged_config = deep_merge(merged_config, config) }

      # Track the actual source for debugging
      merged_config[:__loaded_from] = merged_config[:__source]
      merged_config.delete(:__source)

      # Store base directory of highest-priority config for resolving relative paths
      highest_source = merged_config[:__loaded_from]
      merged_config[:__base_dir] = source_dirs[highest_source] if highest_source

      merged_config
    end
    
    
    def load_config_file(path)
      return {} unless File.exist?(path)

      begin
        config = if File.basename(path) == '.aether_properties'
                   load_properties_file(path)
                 else
                   YAML.load_file(path) || {}
                 end
        symbolize_keys(config)
      rescue => e
        puts "[CONFIG] Error loading #{path}: #{e.message}"
        {}
      end
    end

    # Parse a `.aether_properties` file: flat `key = value` / `key: value`
    # lines with `#`/`!` comments and blank lines. Values stay strings - the
    # accessors coerce scalars downstream (`port` -> to_i, `dev_mode` -> 'true').
    def load_properties_file(path)
      File.readlines(path).each_with_object({}) do |line, config|
        line = line.strip
        next if line.empty? || line.start_with?('#', '!')

        m = line.match(/\A([^=:]+?)\s*[=:]\s*(.*)\z/)
        next unless m

        config[m[1].strip] = m[2].strip
      end
    end

    # The config file (if any) that marks `dir` as a context root. Prefers
    # `.aethercodex` over `.aether_properties` when both are present.
    def config_file_in(dir)
      CONFIG_FILENAMES.each do |name|
        path = File.join(dir, name)
        return path if File.exist?(path)
      end
      nil
    end

    # The directory above which resolution must NOT crawl. Inside the user home
    # dir the boundary is the home dir itself; elsewhere it is the root of the
    # filesystem the search began on.
    def config_boundary(start_dir)
      start = Pathname.new(File.expand_path(start_dir))
      home  = Pathname.new(File.expand_path(Dir.home))
      return home if start == home || start.to_s.start_with?(home.to_s + File::SEPARATOR)

      root = start
      root = root.parent while root != root.parent
      root
    end

    # Directories from `start_dir` up to (and including) the boundary,
    # nearest-first. A file path is treated as its containing directory.
    def upward_dirs(start_dir)
      current  = Pathname.new(File.expand_path(start_dir))
      current  = current.parent if File.file?(current.to_s)
      boundary = config_boundary(current.to_s)
      dirs = []
      loop do
        dirs << current
        break if current == boundary
        current = current.parent
      end
      dirs
    end

    # Every config file found on the walk from `start_dir` to the boundary,
    # nearest-first (most specific first).
    def config_chain(start_dir)
      upward_dirs(start_dir).map { |d| config_file_in(d.to_s) }.compact
    end

    # Walk up from `start_dir` looking for one named config file, within the
    # boundary. Returns its path or nil.
    def find_config_file_upward(start_dir, name)
      upward_dirs(start_dir).each do |d|
        path = File.join(d.to_s, name)
        return path if File.exist?(path)
      end
      nil
    end
    
    
    def symbolize_keys(hash)
      return hash unless hash.is_a?(Hash)
      
      hash.each_with_object({}) do |(key, value), result|
        symbolized_key = key.respond_to?(:to_hermetic_symbol) ? key.to_hermetic_symbol : key
        result[symbolized_key] = if value.is_a?(Hash)
                                  symbolize_keys(value)
                                elsif value.is_a?(Array)
                                  value.map { |v| v.is_a?(Hash) ? symbolize_keys(v) : v }
                                else
                                  value
                                end
      end
    end
    
    
    def deep_merge(first, second)
      merger = proc do |key, v1, v2|
        if Hash === v1 && Hash === v2
          v1.merge(v2, &merger)
        elsif Array === v1 && Array === v2
          v1 + v2
        else
          v2.nil? ? v1 : v2
        end
      end
      first.merge(second, &merger)
    end
    
  end
  
  
  # Model registry — `model` is the only knob a user needs. Each preset maps a
  # known model ID to its fast model, API type and endpoint. A custom model (one
  # not listed here) simply sets `model` + `api-type` + `api-url` directly — no
  # values are templated or derived from anything else.
  MODELS = {
    # DeepSeek
    'deepseek-chat'     => { fast_model: 'deepseek-chat',     api_type: 'deepseek',  api_url: 'https://api.deepseek.com/v1/chat/completions' },
    'deepseek-reasoner' => { fast_model: 'deepseek-chat',     api_type: 'deepseek',  api_url: 'https://api.deepseek.com/v1/chat/completions' },
    # OpenAI
    'gpt-4o'            => { fast_model: 'gpt-4o-mini',       api_type: 'openai',    api_url: 'https://api.openai.com/v1/chat/completions' },
    'gpt-4o-mini'       => { fast_model: 'gpt-4o-mini',       api_type: 'openai',    api_url: 'https://api.openai.com/v1/chat/completions' },
    'gpt-4.1'           => { fast_model: 'gpt-4.1-mini',      api_type: 'openai',    api_url: 'https://api.openai.com/v1/chat/completions' },
    'gpt-4.1-mini'      => { fast_model: 'gpt-4.1-mini',      api_type: 'openai',    api_url: 'https://api.openai.com/v1/chat/completions' },
    'gpt-5'             => { fast_model: 'gpt-5-mini',        api_type: 'openai',    api_url: 'https://api.openai.com/v1/chat/completions' },
    'gpt-5-mini'        => { fast_model: 'gpt-5-mini',        api_type: 'openai',    api_url: 'https://api.openai.com/v1/chat/completions' },
    # Anthropic
    'claude-sonnet-4-5' => { fast_model: 'claude-sonnet-4-5', api_type: 'anthropic', api_url: 'https://api.anthropic.com/v1/messages' },
    'claude-opus-4-5'   => { fast_model: 'claude-opus-4-5',   api_type: 'anthropic', api_url: 'https://api.anthropic.com/v1/messages' },
    'claude-haiku-4-5'  => { fast_model: 'claude-haiku-4-5',  api_type: 'anthropic', api_url: 'https://api.anthropic.com/v1/messages' },
    # Gemini
    'gemini-2.5-pro'    => { fast_model: 'gemini-2.5-flash',  api_type: 'gemini',    api_url: 'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent' },
    'gemini-2.5-flash'  => { fast_model: 'gemini-2.5-flash',  api_type: 'gemini',    api_url: 'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent' }
  }.freeze

  DEFAULT_MODEL = 'deepseek-chat'

  def self.models
    MODELS
  end

  def self.model
    resolve_model(CFG)
  end

  def self.fast_model
    resolve_fast_model(CFG)
  end

  def self.api_type
    resolve_api_type(CFG)
  end

  # Fill every derived key into the merged config so CFG[:model], CFG[:fast_model],
  # CFG[:api_url] and CFG[:api_type] are always present and always consistent.
  # A known `model` (a MODELS preset) contributes its fast model, API type and
  # endpoint; a custom model must supply `api-type` and `api-url` directly.
  def self.apply_model_defaults(config)
    model = resolve_model(config)
    spec = MODELS[model]

    fast_model = resolve_fast_model(config)

    api_type = resolve_api_type(config)

    endpoint = configured_value(config, :api_url)
    endpoint = spec[:api_url] if endpoint.to_s.strip.empty? && spec
    endpoint = ENV['DEEPSEEK_API_URL'] if endpoint.to_s.strip.empty? && !ENV['DEEPSEEK_API_URL'].to_s.strip.empty?
    endpoint = endpoint.sub('{model}', model) if endpoint.to_s.include?('{model}')

    config[:model] = model
    config[:fast_model] = fast_model
    config[:api_type] = api_type
    config[:api_url] = endpoint
    config
  end

  def self.configured_value(config, key)
    env = ENV["AETHER_#{key.to_s.upcase}"]
    return env unless env.to_s.strip.empty?
    value = config[key] || config[key.to_s]
    value unless value.to_s.strip.empty?
  end

  def self.resolve_model(config)
    model = configured_value(config, :model)
    model.to_s.strip.empty? ? DEFAULT_MODEL : model
  end

  def self.resolve_fast_model(config)
    fast_model = configured_value(config, :fast_model)
    return fast_model unless fast_model.to_s.strip.empty?

    spec = MODELS[resolve_model(config)]
    spec ? spec[:fast_model] : resolve_model(config)
  end

  def self.resolve_api_type(config)
    api_type = configured_value(config, :api_type)
    return api_type.to_s.strip.downcase unless api_type.to_s.strip.empty?

    spec = MODELS[resolve_model(config)]
    return spec[:api_type] if spec

    infer_provider_from_url(configured_value(config, :api_url))
  end

  def self.infer_provider_from_url(url)
    u = url.to_s.downcase
    return 'deepseek' if u.include?('deepseek')
    return 'anthropic' if u.include?('anthropic')
    return 'gemini' if u.include?('googleapis.com') || u.include?('generativelanguage')
    return 'openai' if u.include?('openai')
    nil
  end

  # Load configuration hierarchically (initial load).
  # The context is DERIVED from where `aether` is executed: walk up from Dir.pwd
  # to the nearest `.aethercodex` config file — that directory is the context root.
  CFG = apply_model_defaults(load_hierarchical_config(Dir.pwd))
  
  
  # Default values
  DEFAULT_CONFIG = {
    port: 4567,
    model: 'deepseek-chat',
    api_url: 'https://api.deepseek.com/v1/chat/completions',
    'reasoning-model': true,
    'fast-model': 'deepseek-chat',
    'tm-ai': '.aether/',
    'memory-db': '.aether/mnemosyne.db'
  }
  
  
  # Get configuration value with ENV override and default fallback
  def self.[](key)
    env_key = "AETHER_#{key.to_s.upcase}"
    
    # Check ENV first (highest priority)
    return ENV[env_key] if ENV.key?(env_key)
    
    # Check merged configuration (symbol keys)
    return CFG[key] if CFG.key?(key)
    
    # Check merged configuration (string keys)
    return CFG[key.to_s] if CFG.key?(key.to_s)
    
    # Fall back to default
    DEFAULT_CONFIG[key]
  end
  
  
  def self.port
    env_port = ENV['AETHER_PORT']
    return env_port.to_i if env_port
    
    config_port = CFG[:port] || CFG['port']
    return config_port.to_i if config_port
    
    DEFAULT_CONFIG[:port]
  end
  
  
  def self.api_key
    [ENV['AETHER_API_KEY'], CFG[:api_key], CFG['api-key'], ENV['DEEPSEEK_API_KEY']]
      .find { |value| !value.to_s.strip.empty? }
  end


  def self.api_url
    [ENV['AETHER_API_URL'], CFG[:api_url], ENV['DEEPSEEK_API_URL']]
      .find { |value| !value.to_s.strip.empty? }
  end
  
  
  # Check if dev mode is enabled (allows dangerous instruments)
  def self.dev_mode?
    val = CFG[:dev_mode] || CFG['dev_mode']
    val == true || val.to_s.downcase == 'true'
  end

  # Check if configuration is loaded from specific source
  def self.loaded_from_project?
    CFG[:__loaded_from] == :project
  end
  
  
  def self.loaded_from_home?
    CFG[:__loaded_from] == :home
  end
  
  
  def self.loaded_from_bundle?
    CFG[:__loaded_from] == :bundle
  end
  
  
  # Debug method to show loaded configuration sources
  def self.debug_info
    {
      port: port,
      api_key: api_key ? "#{api_key[0..8]}..." : nil,
      api_url: api_url,
      model: self[:model] || self['model'],
      reasoning_model: self[:'reasoning-model'] || self['reasoning-model'],
      config_sources: CFG.select { |k, _| k.to_s.start_with?('__loaded_from') }
    }
  end
  
  
  # Find the config file (`.aethercodex` or `.aether_properties`) that identifies
  # the context for `start_dir`, walking up parent directories to the boundary
  # (home dir when started inside home, otherwise the filesystem root). Returns
  # the config file path, or nil when no config exists anywhere up the chain.
  def self.resolve_path(start_dir = Dir.pwd)
    config_chain(start_dir).first
  end


  # The context root is DERIVED, never switched: walk up from the current
  # working directory (where `aether` is executed) to the nearest `.aethercodex`
  # config file — that directory IS the context. Falls back to Dir.pwd when no
  # config file exists anywhere up the tree.
  def self.project_root
    find_project_root(Dir.pwd)
  end

  def self.find_project_root(start_dir)
    cfg = resolve_path(start_dir)
    return File.dirname(cfg) if cfg

    expanded = Pathname.new(File.expand_path(start_dir))
    expanded = expanded.parent if File.file?(expanded.to_s)
    expanded.to_s
  end


  # The name this context advertises to peers. An explicit `name:` key in
  # .aethercodex always wins; otherwise it derives from the project root
  # folder — never the folder of the last-opened file.
  def self.project_name
    name = CFG[:name] || CFG['name']
    return name.to_s.strip unless name.to_s.strip.empty?
    File.basename(project_root.to_s)
  end


  # Runtime data directory for the derived context: `<root>/.aether/`.
  def self.tm_ai_dir
    path = File.join(project_root, '.aether')
    FileUtils.mkdir_p(path)
    path
  rescue Errno::EACCES, Errno::EROFS
    fallback = File.expand_path('~/.aether/')
    FileUtils.mkdir_p(fallback)
    fallback
  end
  
  
  # Unified memory database: always `<context>/.aether/mnemosyne.db`.
  def self.memory_db_path
    path = File.join(project_root, '.aether', 'mnemosyne.db')
    FileUtils.mkdir_p(File.dirname(path))
    path
  rescue Errno::EACCES, Errno::EROFS
    fallback = File.expand_path('~/.aether/mnemosyne.db')
    FileUtils.mkdir_p(File.dirname(fallback))
    fallback
  end
  
  
  # Get the log file path
  def self.log_file_path
    File.join(tm_ai_dir, 'limen.log')
  end
  
  
  # Re-read the hierarchical config in place from the current working directory.
  def self.reload!
    CFG.replace(apply_model_defaults(load_hierarchical_config(Dir.pwd)))
  end
  
  
  # Get custom allowed commands from configuration
  def self.allowed_commands
    custom_commands = CFG[:allowed_commands] || CFG['allowed-commands'] || []
    
    # Handle wildcard - allow all commands (check for string with quotes too)
    return [//] if custom_commands == '*' || custom_commands == ['*'] ||
                   custom_commands == '"*"' || custom_commands.to_s.strip == '*'
    
    # Handle comma-separated string (e.g., "git,ls,cat")
    custom_commands = custom_commands.split(',').map(&:strip) if custom_commands.is_a?(String)
    
    # Ensure array
    custom_commands = Array(custom_commands)
    
    # Convert string commands to regex patterns
    custom_commands.map { |cmd| cmd.is_a?(Regexp) ? cmd : /^#{Regexp.escape(cmd.to_s)}\b/ }
  end
  
  # Get custom blocked commands from configuration
  def self.blocked_commands
    custom_commands = CFG[:blocked_commands] || CFG['blocked-commands'] || []
    return [] if custom_commands == '*' || custom_commands == ['*']
    custom_commands = custom_commands.split(',').map(&:strip) if custom_commands.is_a?(String)
    Array(custom_commands).map { |cmd| cmd.is_a?(Regexp) ? cmd : /^#{Regexp.escape(cmd.to_s)}\b/ }
  end

  # Get annotated related contexts from configuration (`contexts:` section).
  # Canonical form is a list of { name, port, description, tags } hashes —
  # `name` is a value (not a key), so hyphenated directory names survive
  # symbolization intact. A name → settings map is also accepted as a fallback.
  # Returns a hash keyed by context name with normalized symbol keys.
  def self.contexts
    contexts_from(CFG[:contexts] || CFG['contexts'] || [])
  end

  # Parse a raw `contexts:` value (already symbolized) into a name-keyed hash.
  def self.contexts_from(raw)
    list = case raw
           when Hash  then raw.map { |name, s| s.is_a?(Hash) ? s.merge(name: name) : { name: name } }
           when Array then raw
           else []
           end

    list.each_with_object({}) do |entry, acc|
      next unless entry.is_a?(Hash)

      name = (entry[:name] || entry['name']).to_s.strip
      next if name.empty?

      acc[name] = {
        port: (entry[:port] || entry['port'])&.to_i,
        description: (entry[:description] || entry['description']),
        tags: Array(entry[:tags] || entry['tags']).map(&:to_s)
      }.compact
    end
  end

  # Locate the `.aethercodex` that write_contexts will splice into. Walks up
  # from the working directory within the boundary, returning the first existing
  # `.aethercodex`; falls back to project_root/.aethercodex. (YAML `contexts:`
  # only applies to `.aethercodex`, so the properties variant is not a target.)
  def self.project_config_path
    find_config_file_upward(Dir.pwd, '.aethercodex') || File.join(project_root, '.aethercodex')
  end

  # Render contexts (name-keyed hash) as indented YAML list entries — WITHOUT
  # the `contexts:` key — so write_contexts can splice them into .aethercodex
  # without disturbing surrounding comments. Strings are JSON-quoted, tags as arrays.
  def self.contexts_to_yaml(contexts)
    contexts.map do |name, c|
      lines = ["  - name: #{name.to_s.to_json}"]
      lines << "    port: #{c[:port].to_i}" if c[:port]
      if c[:description] && !c[:description].to_s.empty?
        lines << "    description: #{c[:description].to_s.to_json}"
      end
      tags = Array(c[:tags]).reject(&:empty?)
      lines << "    tags: #{tags.to_json}" unless tags.empty?
      lines.join("\n")
    end.join("\n")
  end

  # Surgically write the `contexts:` section into the project .aethercodex.
  # An existing section (matched by /^contexts:\s*$/) is replaced in place;
  # otherwise the section is appended — preceded by the RELATED CONTEXTS
  # header comment (only if the file does not already carry one).
  # All other lines stay byte-identical. Returns { path:, saved: }.
  def self.write_contexts(contexts)
    path = project_config_path
    lines = File.exist?(path) ? File.readlines(path) : []
    body = contexts_to_yaml(contexts)
    idx = lines.index { |l| l =~ /^contexts:\s*$/ }

    if idx
      finish = idx + 1
      finish += 1 while finish < lines.size && (lines[finish] =~ /^\s/ || lines[finish].strip.empty?)
      lines[idx...finish] = ["contexts:\n"] + body.lines
    else
      lines << "\n" if lines.empty? || !lines.last.end_with?("\n")
      unless lines.join.include?('RELATED CONTEXTS (AetherLink annotations)')
        lines << "# === RELATED CONTEXTS (AetherLink annotations) ================================\n"
      end
      lines << "contexts:\n"
      lines.concat body.lines
    end

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, lines.join)
    reload!
    { path: path, saved: contexts.size }
  end

  # Re-read the hierarchical config in place, so CONFIG.contexts (and every
  # other key) reflects the freshly written .aethercodex immediately — no
  # server restart required. CFG is the live Hash constant; replace() mutates
  # it in place so all existing references observe the new contents.
  def self.reload!
    CFG.replace(apply_model_defaults(load_hierarchical_config(Dir.pwd)))
  end
end
