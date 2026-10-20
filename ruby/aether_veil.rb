# frozen_string_literal: true

require 'fileutils'
require 'io/console'
require 'tempfile'
require 'uri'
require 'yaml'
require_relative 'config'

# AEther Veil - first-run setup, repair and configuration of the local
# AEtherOracle installation. Only `model` is asked of the user; the fast model,
# API type and endpoint come from a preset, or are filled directly for a custom
# model.
module AetherVeil
  MINIMUM_RUBY = Gem::Version.new('3.1')
  CONFIG_PATH = File.expand_path('~/.aethercodex')

  DEFAULT_TEMPLATE = <<~YAML
    # ==========================================================================
    #  .aethercodex - AEther Oracle configuration
    # ==========================================================================
    #  Only `model` is required. Pick a known model and the fast model, API type
    #  and endpoint are filled automatically. For a custom model, fill the three
    #  minimal fields below directly — nothing is derived or templated.
    #
    #  Known models:
    #    deepseek-chat, deepseek-reasoner
    #    gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4.1-mini, gpt-5, gpt-5-mini
    #    claude-sonnet-4-5, claude-opus-4-5, claude-haiku-4-5
    #    gemini-2.5-pro, gemini-2.5-flash
    # ==========================================================================

    model: deepseek-chat

    # API key. Prefer the AETHER_API_KEY environment variable over storing it here.
    # api-key: sk-...

    # --- Custom model (fill the minimal fields directly) -----------------------
    # model:     your-model-id
    # api-type:  openai        # openai | anthropic | gemini | deepseek
    # api-url:   https://api.example.com/v1/chat/completions

    # --- Optional override (normally leave commented out) ----------------------
    # fast-model: deepseek-chat    # fast (flash) model
  YAML

  class << self
    def run(args = [])
      if args.include?('--help') || args.include?('-h')
        print_usage
        return 0
      end

      options = parse_options(args)
      return 2 unless options

      return edit_config if options[:edit] || options[:default]

      report = diagnose
      print_report(report)
      return (report[:ready] && report[:db_ok] && instruments_ok?(report[:instruments])) ? 0 : 1 if options[:check]

      repair_db if options[:repair]

      fresh = !report[:config_exists]
      needs_setup = fresh || !report[:key_present] || options[:repair]

      unless needs_setup
        puts 'AEther is ready. Use `aether veil --repair` to review, or `aether veil --edit` to edit.'
        return report[:ready] ? 0 : 1
      end

      unless $stdin.tty?
        warn 'Setup needs an interactive terminal. Run `aether veil` in a terminal, or set AETHER_API_KEY.'
        return 2
      end

      configure(options[:repair] || fresh, report)
    rescue Interrupt
      puts "\nSetup cancelled; existing configuration was left unchanged."
      130
    rescue StandardError => e
      warn "AEther setup failed: #{e.class}: #{e.message}"
      1
    end

    private

    def print_usage
      puts 'Usage: aether veil [--check | --repair | --default | --edit]'
      puts '  --check    inspect system, configuration and memory DB (no writes)'
      puts '  --repair   review model, repair config and migrate the memory DB'
      puts '  --default  write a documented default ~/.aethercodex (never overwrites)'
      puts '  --edit     write the default if missing, then open it in your editor'
    end

    def parse_options(args)
      flags = %w[--check --repair --default --edit]
      unknown = args - flags
      unless unknown.empty?
        warn "Unknown veil option: #{unknown.first}"
        print_usage
        return nil
      end

      chosen = flags.select { |flag| args.include?(flag) }
      if chosen.size > 1
        warn 'Choose only one of --check, --repair, --default or --edit.'
        print_usage
        return nil
      end

      {
        check: args.include?('--check'),
        repair: args.include?('--repair'),
        edit: args.include?('--edit'),
        default: args.include?('--default')
      }
    end

    def diagnose
      endpoint = CONFIG.api_url
      db = db_status
      instruments = instrument_status
      {
        ruby_ok: Gem::Version.new(RUBY_VERSION) >= MINIMUM_RUBY,
        ruby_version: RUBY_VERSION,
        config_path: CONFIG_PATH,
        config_exists: File.file?(CONFIG_PATH),
        key_present: !CONFIG.api_key.to_s.strip.empty?,
        model: CONFIG.model,
        model_known: CONFIG.models.key?(CONFIG.model),
        api_type: CONFIG.api_type,
        fast_model: CONFIG.fast_model,
        endpoint: endpoint,
        endpoint_valid: valid_url?(endpoint),
        db_path: db[:path],
        db_exists: db[:exists],
        db_version: db[:version],
        db_missing: db[:missing],
        db_singleton: db[:singleton],
        db_error: db[:error],
        db_ok: db[:ok],
        instruments: instruments,
        ready: Gem::Version.new(RUBY_VERSION) >= MINIMUM_RUBY &&
          !CONFIG.api_key.to_s.strip.empty? && valid_url?(endpoint)
      }
    end

    def print_report(report)
      puts 'AEther veil system check'
      puts "  Ruby #{report[:ruby_version]}: #{report[:ruby_ok] ? 'OK' : "needs #{MINIMUM_RUBY}+"}"
      puts "  Model: #{report[:model]}#{report[:model_known] ? '' : ' (custom — api-type/api-url required)'}"
      puts "  API type: #{report[:api_type]}"
      puts "  Flash model: #{report[:fast_model]}"
      puts "  API endpoint: #{report[:endpoint_valid] ? 'OK' : 'invalid or missing'}"
      puts "  API key: #{report[:key_present] ? 'configured' : 'missing'}"
      puts "  User config: #{report[:config_path]}"
      puts "  Memory DB: #{report[:db_path]}"
      if report[:db_error]
        puts "  Memory schema: unreadable (#{report[:db_error]})"
      elsif !report[:db_exists]
        puts '  Memory schema: not created yet (initializes on first run)'
      else
        problems = []
        problems << "missing #{report[:db_missing].join(', ')}" unless report[:db_missing].empty?
        problems << 'singleton schema' if report[:db_singleton]
        state = report[:db_ok] ? 'OK' : "outdated — #{problems.join('; ')}"
        puts "  Memory schema: v#{report[:db_version] || '?'} (#{state})"
      end
      print_instruments(report[:instruments])
      puts '  Provider connection: not tested (no request sent)'
    end

    def print_instruments(inst)
      if inst.nil?
        puts '  Instruments: not probed'
      elsif inst[:loaded]
        state = inst[:healthy] ? 'OK' : "problems — #{inst[:problems].join('; ')}"
        puts "  Instruments: #{inst[:tools]} tools (#{state})"
      else
        puts "  Instruments: unavailable (#{inst[:error]})"
      end
    end

    # `--check` must fail when the instrumentarium is loadable but structurally
    # broken; an unloadable one is reported but not treated as a hard failure
    # (it may simply be a minimal install without the full brain tier).
    def instruments_ok?(inst)
      return true if inst.nil? || !inst[:loaded]
      inst[:healthy]
    end

    # Guarded instrumentarium probe: load the full tool set and run the
    # PrimaMateria audit. Heavy (pulls the oracle stack), so any failure is
    # reported as a diagnosed problem instead of aborting `veil --check`.
    def instrument_status
      require_relative 'instrumentarium/instrumenta'
      audit = Instrumenta::PRIMA_MATERIA.audit
      { loaded: true, tools: audit[:tools], healthy: audit[:healthy], problems: audit[:problems] }
    rescue LoadError => e
      { loaded: false, error: "cannot load instrumentarium: #{e.message}" }
    rescue StandardError => e
      { loaded: false, error: "#{e.class}: #{e.message}" }
    end

    # Path of the unified Mnemosyne database for the current context. Prefers
    # CONFIG's context-scoped location and falls back to the home default.
    def memory_db_path
      CONFIG.memory_db_path
    rescue StandardError
      File.expand_path('~/.aether/mnemosyne.db')
    end

    # Read-only probe of the Mnemosyne DB: schema version and whether the
    # `aegis_state` table exposes every column the Aegis orientation writes.
    # Never mutates the file, so `--check` stays side-effect free.
    def db_status
      path = memory_db_path
      exists = File.file?(path)
      status = { path: path, exists: exists, version: nil, missing: [], singleton: false, ok: true, error: nil }

      begin
        require 'sqlite3'
      rescue LoadError => e
        status[:ok] = false
        status[:error] = "sqlite3 unavailable: #{e.message}"
        return status
      end

      return status unless exists

      begin
        SQLite3::Database.new(path) do |db|
          db.results_as_hash = true
          # Sibling processes may be mid-write; a read-only probe should wait
          # rather than report a false "database is locked" verdict.
          db.busy_timeout = 5000
          row = db.execute("SELECT value FROM meta WHERE key='db_version'").first
          status[:version] = row && row['value']
          cols = db.execute('PRAGMA table_info(aegis_state)').map { |c| c['name'] }
          status[:missing] = %w[temperature created_at working_dir thinking_str].reject { |c| cols.include?(c) }
          table = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='aegis_state'").first
          sql = (table && table['sql']).to_s
          status[:singleton] = sql.include?('CHECK (id = 1)') || sql.include?('CHECK(id=1)')
        end
        status[:ok] = status[:missing].empty? && !status[:singleton]
      rescue StandardError => e
        status[:ok] = false
        status[:error] = "#{e.class}: #{e.message}"
      end
      status
    end

    # Canonical repair: load Mnemosyne and open the connection — `Mnemosyne.db`
    # runs the full migration cascade plus the idempotent aegis_state self-heal,
    # so a divergent/outdated schema converges without duplicating DDL here.
    def repair_db
      path = memory_db_path
      require 'sqlite3'
      require_relative 'mnemosyne/mnemosyne'
      Mnemosyne.db
      version = Mnemosyne.db.execute("SELECT value FROM meta WHERE key='db_version'").first&.[]('value')
      puts "  Memory DB migrated: #{path} (schema v#{version || '?'})"
      true
    rescue LoadError => e
      warn "  Memory DB repair skipped: #{e.message}"
      false
    rescue StandardError => e
      warn "  Memory DB repair failed: #{e.class}: #{e.message}"
      false
    end

    def configure(review, report)
      path = CONFIG_PATH
      config = read_config(path, repair: review)

      model = report[:model]
      api_type = report[:api_type]
      api_url = report[:endpoint]

      if review
        puts "\nReview the model settings. Press Enter to keep a displayed value."
        chosen = prompt("Model (#{CONFIG.models.keys.join(', ')})", model)
        model = chosen unless chosen.to_s.strip.empty?

        unless CONFIG.models.key?(model)
          puts 'Custom model: fill the minimal API fields directly.'
          api_type = prompt('API type (openai | anthropic | gemini | deepseek)', api_type)
          api_url = prompt('API URL', api_url)
        end
      end

      api_key = ensure_api_key(review, CONFIG.models.key?(model) ? CONFIG.models[model][:api_type] : api_type)
      return 1 if api_key.nil?

      config['model'] = model
      if CONFIG.models.key?(model)
        config.delete('api-type')
        config.delete('api-url')
        config.delete('fast-model')
      else
        config['api-type'] = api_type
        config['api-url'] = api_url
      end
      config['api-key'] = api_key unless ENV['AETHER_API_KEY'] || ENV['DEEPSEEK_API_KEY']

      write_config(path, config)
      CONFIG.reload!

      final_report = diagnose
      print_report(final_report)
      if final_report[:ready]
        puts "Setup complete. Configuration saved to #{path}."
        0
      else
        warn 'Configuration was saved, but the system check still has items to repair.'
        1
      end
    end

    def ensure_api_key(review, api_type)
      environment_key = ENV['AETHER_API_KEY'] || ENV['DEEPSEEK_API_KEY']
      current = CONFIG.api_key

      if environment_key
        puts 'The API key comes from the environment; update AETHER_API_KEY (or DEEPSEEK_API_KEY) to change it.'
        return current
      end

      if review && !current.to_s.strip.empty? && !confirm('Replace the configured API key?', default: false)
        return current
      end

      label = api_type.to_s.strip.empty? ? 'API' : api_type.to_s.strip.capitalize
      key = prompt_secret("#{label} API key")
      if key.to_s.strip.empty?
        puts 'No key entered. Setup stopped without changing configuration.'
        return nil
      end
      key.strip
    end

    def edit_config
      path = CONFIG_PATH
      write_template(path)
      open_in_editor(path)
    end

    def write_template(path)
      FileUtils.mkdir_p(File.dirname(path))
      if File.file?(path)
        puts "Keeping existing config: #{path}"
        return
      end

      File.write(path, DEFAULT_TEMPLATE)
      File.chmod(0o600, path) rescue nil
      puts "Wrote a documented default config to #{path}."
    end

    def open_in_editor(path)
      editor = ENV['VISUAL'] || ENV['EDITOR']
      opened = if editor && !editor.strip.empty?
        system(editor, path)
      elsif RUBY_PLATFORM =~ /mswin|mingw|cygwin/
        system(%(start "" "#{path}"))
      else
        system('open', path)
      end

      return 0 if opened

      puts "Open this file in your editor to configure the AEther: #{path}"
      puts
      puts File.read(path)
      1
    end

    def read_config(path, repair: false)
      return {} unless File.file?(path)

      loaded = YAML.load_file(path) || {}
      raise "#{path} must contain a YAML mapping" unless loaded.is_a?(Hash)

      loaded.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    rescue Psych::Exception => e
      unless repair && confirm("#{path} is invalid YAML. Back it up and recreate setup values?", default: false)
        raise "Cannot read #{path}: #{e.message}. Use `aether veil --repair` to review recovery options."
      end

      {}
    end

    def write_config(path, config)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory)
      if File.file?(path)
        backup = "#{path}.backup-#{Time.now.strftime('%Y%m%d-%H%M%S-%L')}.bak"
        FileUtils.cp(path, backup)
        puts "Saved the previous config to #{backup}."
      end
      Tempfile.create(['aether-veil-', '.yml'], directory) do |temp|
        temp.write(YAML.dump(config))
        temp.flush
        temp.fsync
        temp.close
        File.chmod(0o600, temp.path) rescue nil
        FileUtils.mv(temp.path, path, force: true)
      end
      File.chmod(0o600, path) rescue nil
    end

    def valid_url?(endpoint)
      uri = URI.parse(endpoint.to_s)
      %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    def prompt(label, default)
      suffix = default.to_s.empty? ? '' : " [#{default}]"
      print "#{label}#{suffix}: "
      answer = $stdin.gets&.strip
      answer.nil? || answer.empty? ? default.to_s : answer
    end

    def prompt_secret(label)
      print "#{label}: "
      value = $stdin.noecho(&:gets).to_s.strip
      puts
      value
    rescue IOError, NoMethodError
      warn 'Secure terminal input is unavailable; API keys are not read from non-interactive input.'
      nil
    end

    def confirm(label, default: false)
      suffix = default ? '[Y/n]' : '[y/N]'
      print "#{label} #{suffix}: "
      answer = $stdin.gets.to_s.strip.downcase
      return default if answer.empty?

      %w[y yes].include?(answer)
    end
  end
end