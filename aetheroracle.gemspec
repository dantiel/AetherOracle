# frozen_string_literal: true

require_relative 'lib/aetheroracle/version'

Gem::Specification.new do |spec|
  spec.name    = 'aetheroracle'
  spec.version = AetherOracle::VERSION
  spec.authors = ['AetherOracle']
  spec.summary = 'AetherOracle — one oracle, many voices. The shared brain CLI.'
  spec.description = <<~DESC.strip
    The shared core of the AetherCodex editor: the brain (limen.rb daemon,
    oracle, mnemosyne, instrumentarium) plus a pure-stdlib link tier that
    discovers oracle peers on the LAN and routes turns to them. Installed on
    any OS, that OS becomes an Aether OS — the aether is everywhere, and the
    voice finds it.
  DESC
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/dantiel/AetherOracle'

  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir.chdir(__dir__) do
    Dir[
      'lib/**/*.rb',
      'ruby/**/*.rb',
      'ruby/**/*.md',
      'ruby/vendored/**/*',
      'resources/**/*',
      'platform/**/*',
      'protocol.md',
      'README.md',
      'aetheroracle.gemspec'
    ]
      .reject { |f| f.include?('/.vendor_bundle/') || f.include?('/.bundle/') || f.include?('/.portable/') }
      .select { |f| File.file?(f) }
  end

  spec.bindir        = 'exe'
  spec.executables   = %w[aetheroracle aether oracle oracleaether ae aero orae]
  spec.require_paths = ['lib']

  # Runtime dependencies — the brain tier. The native gems (sqlite3, tiktoken_ruby)
  # ship precompiled binaries for x64-mingw-ucrt / x86_64-darwin / linux at these
  # pinned ranges, so no Rust or source build is required on Windows.
  spec.add_dependency 'sinatra', '~> 3.0'
  spec.add_dependency 'faye-websocket', '~> 0.11.0'
  spec.add_dependency 'thin', '~> 1.8'
  spec.add_dependency 'faraday', '~> 2.8'
    spec.add_dependency 'sqlite3', '~> 1.5'
    spec.add_dependency 'yaml', '~> 0.4'
  spec.add_dependency 'redcarpet', '~> 3.6'
  spec.add_dependency 'rouge', '~> 4.6'
  spec.add_dependency 'ruby-enum', '~> 1.0'
  spec.add_dependency 'textpow', '~> 1.4'
  spec.add_dependency 'differ', '~> 0.1.2'
  spec.add_dependency 'tiktoken_ruby', '~> 0.0.9'
  spec.add_dependency 'diffy', '~> 3.4'
  spec.add_dependency 'dotenv', '~> 3.1'
  spec.add_dependency 'dotenvx', '~> 0.0.2'
  spec.add_dependency 'concurrent-ruby', '~> 1.3'

  spec.add_development_dependency 'rspec', '~> 3.13'
end