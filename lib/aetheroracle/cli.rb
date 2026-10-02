# frozen_string_literal: true

require_relative 'link'

module AetherOracle
  # Link-tier commands stay pure stdlib. Veil uses a lightweight setup path;
  # other brain commands load the full CLI only when requested.
  module CLI
    BRAIN_COMMANDS = %w[ask chamber dialog talk server config context task logs repl veil
                        read cat inspect ov write new mv rename files ast grep notes mem
                        note history hist search find aegis seal seals].freeze

    def self.run(argv)
      command = argv.first

      # Hermetic default: bare `aetheroracle` enters the Dialog-Kammer, not a
      # dry usage line. Link-tier commands (peers / heartbeat / invoke) stay
      # pure-stdlib and are dispatched below without loading the brain.
      if command.nil? || BRAIN_COMMANDS.include?(command)
        status = run_brain(argv)
        return status.is_a?(Integer) ? status : 0
      end

      Link.run(argv.dup)
      0
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