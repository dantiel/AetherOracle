# frozen_string_literal: true

require_relative 'link'

module AetherOracle
  # Link-tier commands stay pure stdlib. Veil uses a lightweight setup path;
  # other brain commands load the full CLI only when requested.
  module CLI
    BRAIN_COMMANDS = %w[ask server config context task logs repl veil].freeze

    def self.run(argv)
      unless BRAIN_COMMANDS.include?(argv.first)
        Link.run(argv.dup)
        return 0
      end

      status = run_brain(argv)
      status.is_a?(Integer) ? status : 0
    end

    def self.run_brain(argv)
      if argv.first == 'veil'
        require_relative '../../ruby/config'
        require_relative '../../ruby/aether_veil'
        return AetherVeil.run(argv.drop(1))
      end

      # htmldiff is vendored because its source is not represented by the gemspec.
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