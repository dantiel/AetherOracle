# frozen_string_literal: true

require_relative '../config'
require 'tmpdir'
require 'rspec'

# Kontext-Fenster: chirurgische .aethercodex-Schreibung + Normalisierung.
RSpec.describe 'AetherContexts' do
  around do |example|
    Dir.mktmpdir('aether_contexts_spec') do |dir|
      @tmpdir = dir
      begin
        example.run
      ensure
        ENV.delete('TM_PROJECT_DIRECTORY')
      end
    end
  end

  def fixture_path(name = '.aethercodex')
    File.join(@tmpdir, name)
  end

  def stub_config_path!
    allow(CONFIG).to receive(:project_config_path).and_return(fixture_path)
  end

  describe CONFIG do
    describe '.contexts_to_yaml' do
      it 'renders indented list entries with JSON-quoted values' do
        yaml = CONFIG.contexts_to_yaml(
          'project-alpha' => { port: 4568, description: 'Main app', tags: %w[shared-models] },
          'beta'         => { description: 'Say "hi"' }
        )

        expect(yaml).to include('  - name: "project-alpha"')
        expect(yaml).to include('    port: 4568')
        expect(yaml).to include('    description: "Main app"')
        expect(yaml).to include('    tags: ["shared-models"]')
        expect(yaml).to include('  - name: "beta"')
        expect(yaml).to include('    description: "Say \"hi\""')
      end

      it 'omits optional keys when absent' do
        expect(CONFIG.contexts_to_yaml('solo' => {})).to eq('  - name: "solo"')
      end
    end

    describe '.write_contexts' do
      it 'replaces an existing contexts: section, keeping the comment header byte-identical' do
        header = "# === RELATED CONTEXTS (AetherLink annotations) ===\n# keep me exactly\n"
        File.write(fixture_path, header + <<~YAML)
          contexts:
            - name: old-peer
              port: 1111
              description: outdated
        YAML

        stub_config_path!
        result = CONFIG.write_contexts(
          'project-alpha' => { port: 4568, description: 'Main app', tags: %w[shared] }
        )

        content = File.read(fixture_path)
        expect(result[:saved]).to eq(1)
        expect(result[:path]).to eq(fixture_path)
        expect(content).to start_with(header) # byte-identical comment header
        expect(content).not_to include('old-peer')
        expect(content).to include('  - name: "project-alpha"')
        expect(content).to include('    port: 4568')
        expect(content).to include('    description: "Main app"')
        expect(content).to include('    tags: ["shared"]')
      end

      it 'appends header + contexts: section when no contexts: line exists' do
        File.write(fixture_path, "# plain comment\nport: 4567\n")

        stub_config_path!
        CONFIG.write_contexts('peer' => { port: 4569, description: 'daemon' })

        content = File.read(fixture_path)
        expect(content).to start_with("# plain comment\nport: 4567\n")
        expect(content).to include('RELATED CONTEXTS (AetherLink annotations)')
        expect(content).to include("contexts:\n  - name: \"peer\"")
        expect(content).to include('    port: 4569')
        expect(content).to include('    description: "daemon"')
      end

      it 'does not duplicate the RELATED CONTEXTS header when it already exists' do
        File.write(fixture_path, "# === RELATED CONTEXTS (AetherLink annotations) ===\n# commented example\n# contexts:\n")

        stub_config_path!
        CONFIG.write_contexts('peer' => { port: 4569 })

        content = File.read(fixture_path)
        expect(content.scan('RELATED CONTEXTS (AetherLink annotations)').size).to eq(1)
        expect(content).to include("contexts:\n  - name: \"peer\"")
      end

      it 'creates the file when it does not exist' do
        stub_config_path!
        result = CONFIG.write_contexts('brand-new' => { port: 4567 })

        expect(File.exist?(fixture_path)).to be true
        expect(result[:saved]).to eq(1)
        expect(File.read(fixture_path)).to include("contexts:\n  - name: \"brand-new\"")
      end

      it 'reloads CFG so saved annotations are visible without a restart' do
        stub_config_path!
        allow(CONFIG).to receive(:load_hierarchical_config)
          .and_return(contexts: [{ name: 'peer', description: 'daemon' }])

        CONFIG.write_contexts('peer' => { description: 'daemon' })

        expect(CONFIG.contexts).to have_key('peer')
        expect(CONFIG.contexts['peer'][:description]).to eq('daemon')
      end
    end

    describe '.project_root' do
      it 'prefers TM_PROJECT_DIRECTORY over Dir.pwd' do
        root = File.join(@tmpdir, 'root-project')
        ENV['TM_PROJECT_DIRECTORY'] = root
        allow(Dir).to receive(:pwd).and_return(File.join(@tmpdir, 'root-project', 'sub', 'last-opened'))

        expect(CONFIG.project_root).to eq(root)
      end

      it 'falls back to Dir.pwd when TM_PROJECT_DIRECTORY is absent' do
        allow(Dir).to receive(:pwd).and_return(@tmpdir)
        expect(CONFIG.project_root).to eq(@tmpdir)
      end
    end

    describe '.project_name' do
      it 'derives from the project root folder, not the last-opened folder' do
        root = File.join(@tmpdir, 'root-project')
        # Isolate from the bundle .aethercodex (name: AetherCodex) loaded at require time.
        stub_const('CONFIG::CFG', {})
        ENV['TM_PROJECT_DIRECTORY'] = root
        allow(Dir).to receive(:pwd).and_return(File.join(@tmpdir, 'root-project', 'sub', 'last-opened'))

        expect(CONFIG.project_name).to eq('root-project')
      end

      it 'prefers an explicit name: key over the folder name' do
        stub_const('CONFIG::CFG', { name: 'explicit-app-name' })
        ENV['TM_PROJECT_DIRECTORY'] = File.join(@tmpdir, 'root-project')

        expect(CONFIG.project_name).to eq('explicit-app-name')
      end
    end

    describe '.project_config_path' do
      it 'walks up from TM_PROJECT_DIRECTORY to the first existing .aethercodex' do
        File.write(fixture_path, 'port: 4567')
        nested = File.join(@tmpdir, 'a', 'b')
        FileUtils.mkdir_p(nested)
        ENV['TM_PROJECT_DIRECTORY'] = nested

        expect(CONFIG.project_config_path).to eq(fixture_path)
      end

      it 'falls back to project_root/.aethercodex when none exists upward' do
        ENV['TM_PROJECT_DIRECTORY'] = @tmpdir
        expect(CONFIG.project_config_path).to eq(fixture_path)
      end
    end

    describe '.contexts_from' do
      it 'normalizes: drops empty names, port→int, tags→string array' do
        normalized = CONFIG.contexts_from([
          { name: '   ', port: '4568' },
          { name: 'alpha', port: '4568', tags: [:a, 'b', nil] },
          { name: 'beta', tags: 'single' }
        ])

        expect(normalized.keys).to eq(%w[alpha beta])
        expect(normalized['alpha'][:port]).to eq(4568)
        expect(normalized['alpha'][:tags]).to eq(['a', 'b', ''])
        expect(normalized['beta'][:tags]).to eq(%w[single])
      end
    end
  end
end