# frozen_string_literal: true

require_relative 'link'

module AetherOracle
  # Top-level CLI dispatcher. Link-tier commands run in-process (pure stdlib);
  # brain-tier commands load the brain (ruby/cli.rb) lazily, so requiring this
  # gem never forces the brain's native gems until they are actually needed.
  module CLI
    BRAIN_COMMANDS = %w[ask server config task logs repl].freeze

    def self.run(argv)
      command = argv.first
      if BRAIN_COMMANDS.include?(command)
        run_brain(argv)
      else
        Link.run(argv.dup)
      end
      0
    end

        def self.run_brain(argv)
          # Vendored third-party source the gemspec cannot express (htmldiff is a
          # git-only gem): put it on the load path before the brain requires it.
          vendor = File.expand_path('../../ruby/vendored/htmldiff', __dir__)
          $LOAD_PATH.unshift(vendor) unless $LOAD_PATH.include?(vendor)
    
          require_relative '../../ruby/cli'
      ARGV.replace(argv.dup)
      ÆtherCodexCLI.new.run
    rescue LoadError => e
      warn "brain unavailable: #{e.message}"
      warn 'install the brain gems first: gem install aetheroracle'
      exit 1
    end
  end
end