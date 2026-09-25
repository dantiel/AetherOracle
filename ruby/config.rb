require 'fileutils'
require 'yaml'
require 'json'
require 'pathname'
require 'dotenv'
require_relative 'instrumentarium/metaprogramming_utils'



# Unified hierarchical configuration loading system
# Loads .aethercodex files from multiple sources with precedence:
# 1. Current project directory (highest priority)
# 2. User home directory (~/.aethercodex)
# 3. Bundle Support directory (lowest priority)
class CONFIG
  
  class << self
    
    def load_hierarchical_config(start_dir = Dir.pwd)
      configs = []
      source_dirs = {}
      
      # 1. Bundle Support directory (lowest priority)
      bundle_config_path = File.expand_path('.aethercodex', __dir__)
      if File.exist?(bundle_config_path)
        bundle_config = load_config_file(bundle_config_path)
        bundle_config[:__source] = :bundle
        configs << bundle_config
        source_dirs[:bundle] = File.dirname(bundle_config_path)
      end
      
      # 2. User home directory
      home_config_path = File.expand_path('~/.aethercodex')
      if File.exist?(home_config_path)
        home_config = load_config_file(home_config_path)
        home_config[:__source] = :home
        configs << home_config
        source_dirs[:home] = File.dirname(home_config_path)
      end
      
      # 3. Current project directory and parent directories (highest priority)
      current_dir = Pathname.new(start_dir)
      root_dir = Pathname.new('/')
      
      # Traverse up directory tree until reaching root
      while current_dir != root_dir
        project_config_path = current_dir + '.aethercodex'
        if File.exist?(project_config_path.to_s)
          project_config = load_config_file(project_config_path.to_s)
          project_config[:__source] = :project
          configs << project_config
          source_dirs[:project] = File.dirname(project_config_path.to_s)
          break # Stop at first project config found
        end
        current_dir = current_dir.parent
      end
      
      # Merge all configs with proper precedence (first = lowest, last = highest)
      merged_config = {}
      configs.each do |config|
        merged_config = deep_merge(merged_config, config)
      end
      
      # Track the actual source for debugging
      merged_config[:__loaded_from] = merged_config[:__source]
      merged_config.delete(:__source)
      
      # Store base directory of highest-priority config for resolving relative paths
      highest_source = merged_config[:__loaded_from]
      merged_config[:__base_dir] = source_dirs[highest_source] if highest_source
      
      # puts "[CONFIG][LOAD_HIERARCHICAL_CONFIG]: merged_config: #{merged_config.inspect}"
      
      merged_config
    end
    
    
    def load_config_file(path)
      return {} unless File.exist?(path)
      
      begin
        config = YAML.load_file(path) || {}
        symbolize_keys(config)
      rescue => e
        puts "[CONFIG] Error loading #{path}: #{e.message}"
        {}
      end
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
  
  
  # Load configuration hierarchically (initial load).
  # Start the upward traversal from the STABLE project root (TM_PROJECT_DIRECTORY),
  # never from Dir.pwd — which drifts to the folder of the last-opened file and can
  # even land outside the project tree, loading the wrong .aethercodex.
  CFG = load_hierarchical_config(ENV['TM_PROJECT_DIRECTORY'] || Dir.pwd)
  
  
  # Default values
  DEFAULT_CONFIG = {
    port: 4567,
    model: 'deepseek-chat',
    'api-url': 'https://api.deepseek.com/v1/chat/completions',
    'reasoning-model': true,
    'fast-model': 'deepseek-v4-flash',
    'tm-ai': '.tm-ai/',
    'memory-db': '.tm-ai/memory.db'
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
    ENV['AETHER_API_KEY'] || CFG[:api_key] || CFG['api-key']
  end
  
  
  def self.api_url
    ENV['AETHER_API_URL'] || CFG[:api_url] || CFG['api-url'] || DEFAULT_CONFIG[:api_url]
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
  
  
  # Resolve a path relative to the config base directory, handling absolute paths.
  # Precedence: TM_PROJECT_DIRECTORY env var > config file directory > Dir.pwd.
  def self.resolve_path(relative_path)
    # Handle absolute paths (starting with "/")
    return relative_path if relative_path.start_with?('/')
    
    # For relative paths, resolve relative to the highest-priority config's directory
    project_root = ENV['TM_PROJECT_DIRECTORY']
    
    # Fall back to config base dir only if outside the bundle (pristine copies are read-only)
    if !project_root && CFG[:__base_dir]
      bundle_dir = File.expand_path('..', __dir__)
      project_root = CFG[:__base_dir] unless CFG[:__base_dir].start_with?(bundle_dir)
    end
    
    project_root ||= Dir.pwd
    File.join(project_root, relative_path)
  end


  # The project root directory. TextMate exposes the stable project root via
  # TM_PROJECT_DIRECTORY; Dir.pwd, by contrast, drifts to the folder of the
  # most recently opened file. Resolve context identity to this root, not pwd.
  # (TM_DIRECTORY is deliberately skipped — it tracks the active file's folder,
  # i.e. exactly the "last-opened folder" drift we want to avoid.)
  def self.project_root
    root = ENV['TM_PROJECT_DIRECTORY'] || Dir.pwd
    root = File.dirname(root) if root && File.file?(root)
    root
  end


  # The name this context advertises to peers. An explicit `name:` key in
  # .aethercodex always wins; otherwise it derives from the project root
  # folder — never the folder of the last-opened file.
  def self.project_name
    name = CFG[:name] || CFG['name']
    return name.to_s.strip unless name.to_s.strip.empty?
    File.basename(project_root.to_s)
  end


  # Get the tm-ai directory path
  def self.tm_ai_dir
    path = resolve_path(self[:tm_ai] || '.tm-ai/')
    FileUtils.mkdir_p(path)
    path
  rescue Errno::EACCES, Errno::EROFS
    fallback = File.expand_path('~/.tm-ai/')
    FileUtils.mkdir_p(fallback)
    fallback
  end
  
  
  # Get the memory database path
  def self.memory_db_path
    path = resolve_path(self[:memory_db] || '.tm-ai/memory.db')
    FileUtils.mkdir_p(File.dirname(path))
    path
  rescue Errno::EACCES, Errno::EROFS
    fallback = File.expand_path('~/.tm-ai/memory.db')
    FileUtils.mkdir_p(File.dirname(fallback))
    fallback
  end
  
  
  # Get the log file path
  def self.log_file_path
    File.join(tm_ai_dir, 'limen.log')
  end
  
  
  # Get the PID file path
  def self.pid_file_path
    File.join(tm_ai_dir, 'limen.pid')
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

  # Locate the project .aethercodex that write_contexts will splice into.
  # Walks up from TM_PROJECT_DIRECTORY (or Dir.pwd) to the filesystem root,
  # returning the first existing .aethercodex; falls back to project_root/.aethercodex.
  def self.project_config_path
    project_root = ENV['TM_PROJECT_DIRECTORY'] || Dir.pwd
    current_dir = Pathname.new(project_root)
    root_dir = Pathname.new('/')
    while current_dir != root_dir
      candidate = current_dir + '.aethercodex'
      return candidate.to_s if File.exist?(candidate.to_s)
      current_dir = current_dir.parent
    end
    File.join(project_root, '.aethercodex')
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
    CFG.replace(load_hierarchical_config(ENV['TM_PROJECT_DIRECTORY'] || Dir.pwd))
  end
end