# frozen_string_literal: true

require_relative '../aether_link'
require 'tmpdir'
require 'rspec'

RSpec.describe AetherLink do
  before do
    AetherLink.instance_variable_set(:@known_contexts, {})
    allow(AetherLink).to receive(:heartbeat_from).and_return(nil)
    allow(AetherLink).to receive(:own_port).and_return(4567)
  end

  describe '.discover! with annotations' do
    it 'registers annotated-only contexts as stale, annotated entries' do
      allow(CONFIG).to receive(:contexts).and_return(
        'project-alpha' => { port: 4568, description: 'Main app', tags: %w[shared] }
      )

      AetherLink.discover!

      ctx = AetherLink.lookup('project-alpha')
      expect(ctx).not_to be_nil
      expect(ctx[:stale]).to be true
      expect(ctx[:annotated]).to be true
      expect(ctx[:description]).to eq('Main app')
      expect(ctx[:tags]).to eq(%w[shared])
      expect(ctx[:port]).to eq(4568)
    end

    it 'overlays annotations onto a discovered context of the same name' do
      AetherLink.instance_variable_set(:@known_contexts,
        'project-alpha' => { port: 4568, path: '/x', capabilities: [], version: nil,
                             busy: false, active_tasks: [], last_seen: Time.now, stale: false })

      # The peer still answers on 4568 → it stays online through the rescan.
      allow(AetherLink).to receive(:heartbeat_from).with(4568).and_return(
        name: 'project-alpha', path: '/x', capabilities: [], version: nil,
        busy: false, active_tasks: []
      )

      allow(CONFIG).to receive(:contexts).and_return(
        'project-alpha' => { description: 'annotated', tags: %w[doc] }
      )

      AetherLink.discover!

      ctx = AetherLink.lookup('project-alpha')
      expect(ctx[:stale]).to be false
      expect(ctx[:description]).to eq('annotated')
      expect(ctx[:tags]).to eq(%w[doc])
      expect(ctx[:annotated]).to be true
    end

    it 'binds an annotated alias to a discovered context by port' do
      AetherLink.instance_variable_set(:@known_contexts,
        'myproject' => { port: 4568, path: '/x', capabilities: [], version: nil,
                         busy: false, active_tasks: [], last_seen: Time.now, stale: false })

      allow(CONFIG).to receive(:contexts).and_return(
        'the-main-app' => { port: 4568, description: 'alias' }
      )

      AetherLink.discover!

      expect(AetherLink.lookup('the-main-app')).to eq(AetherLink.lookup('myproject'))
      expect(AetherLink.lookup('the-main-app')[:description]).to eq('alias')
    end
  end

  describe 'CONFIG.contexts_from' do
    it 'preserves hyphenated names when given the list form' do
      path = File.join(Dir.tmpdir, 'aethercodex_contexts_spec.yml')
      File.write(path, <<~YAML)
        contexts:
          - name: my-project
            port: 4568
            description: peer
            tags: [a, b]
      YAML

      cfg = CONFIG.load_config_file(path)
      contexts = CONFIG.contexts_from(cfg[:contexts])

      expect(contexts).to have_key('my-project')
      expect(contexts['my-project'][:port]).to eq(4568)
      expect(contexts['my-project'][:description]).to eq('peer')
      expect(contexts['my-project'][:tags]).to eq(%w[a b])
    ensure
      FileUtils.rm_f(path) rescue nil
    end
  end
end