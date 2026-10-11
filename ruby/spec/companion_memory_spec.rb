# frozen_string_literal: true

require 'rspec'
require 'tmpdir'

TEST_DB = File.join(Dir.tmpdir, "companion_spec_#{Process.pid}.db")
ENV['AETHER_MEMORY_DB'] = TEST_DB

require_relative '../mnemosyne/mnemosyne'
require_relative '../instrumentarium/companion_programs'

RSpec.describe 'Companion memory (facet crystal)' do
  after(:all) { File.delete(TEST_DB) if File.exist?(TEST_DB) }

  describe 'procedural layer (recipe)' do
    it 'falls back to the seed constant when no DB recipe exists' do
      r = CompanionPrograms.recipe(:fenrir)
      expect(r[:output_type]).to eq('deletion_plan')
      expect(r[:steps]).to include('Lösch-Kandidaten identifizieren')
      expect(r[:tools]).to include('file_overview')
    end

    it 'persists and reloads an evolving recipe with JSON steps/tools' do
      Mnemosyne.companion_save_recipe glyph: :fenrir, trigger: 't', steps: %w[a b],
                                      tools: %w[x], output_type: 'deletion_plan'
      r = Mnemosyne.companion_recipe(:fenrir)
      expect(r[:steps]).to eq(%w[a b])
      expect(r[:tools]).to eq(%w[x])
    end
  end

  describe 'identitary layer (state)' do
    it 'accumulates self-state per glyph' do
      Mnemosyne.companion_save_state glyph: :fenrir, summary: '847 Zeilen gestutzt',
                                     score: 9, domain_model: 'reduction_ledger: 847'
      s = Mnemosyne.companion_state(:fenrir)
      expect(s[:summary]).to eq('847 Zeilen gestutzt')
      expect(s[:score]).to eq(9)
      expect(s[:domain_model]).to eq('reduction_ledger: 847')
    end
  end

  describe 'episodic layer (facet notes)' do
    it 'tags notes with facet:glyph and recalls only that facet' do
      Mnemosyne.companion_remember_facet content: 'Regex-Emoji-Bug', facet: :fenrir, tags: %w[code]
      Mnemosyne.companion_remember_facet content: 'N+1 gefunden', facet: :undine, tags: %w[code]

      fenrir_notes = Mnemosyne.companion_recall_facet(:fenrir, query: 'regex')
      expect(fenrir_notes.map { |n| n[:content] }).to include('Regex-Emoji-Bug')
      expect(fenrir_notes.map { |n| n[:content] }).not_to include('N+1 gefunden')
    end
  end

  describe 'system prompt wiring' do
    it 'composes persona + protocol + memory' do
      prompt = CompanionPrograms.build_system_prompt(:fenrir, 'PERSONA')
      expect(prompt).to include('PERSONA')
      expect(prompt).to include('COMPANION PROTOCOL')
      expect(prompt).to include('COMPANION MEMORY')
    end

    it 'commands the final commit step so the companion self-specializes' do
      prompt = CompanionPrograms.build_system_prompt(:fenrir, 'PERSONA')
      expect(prompt).to include('ABSCHLUSS')
      expect(prompt).to include('fenrir_commit')
      expect(prompt).to include('VEIL')
    end
  end

  describe 'the veil (Aegis ↔ Companion integration)' do
    before do
      Mnemosyne.aegis = { tags: ['code'], summary: 'prior orientation',
                          temperature: 1.0, working_dir: nil, thinking: nil }
    end

    it 'veils persona + accumulated self into the Aegis orientation' do
      Mnemosyne.companion_save_state glyph: :fenrir, summary: '847 Zeilen gestutzt'
      previous = Mnemosyne.companion_veil(:fenrir, 'PERSONA-FENRIR')

      expect(Mnemosyne.aegis[:tags]).to include('facet:fenrir')
      expect(Mnemosyne.aegis[:summary]).to include('PERSONA-FENRIR')
      expect(Mnemosyne.aegis[:summary]).to include('847 Zeilen gestutzt')
      expect(previous[:summary]).to eq('prior orientation')
    end

    it 'opens the facet memory flow — facet notes reach recall_aegis_notes while veiled' do
      Mnemosyne.companion_remember_facet content: 'Lösch-Kandidat: cli.rb', facet: :fenrir
      Mnemosyne.companion_veil(:fenrir, 'PERSONA')

      notes = Mnemosyne.recall_aegis_notes
      expect(notes.map { |n| n[:content] }.join).to include('cli.rb')
    end

    it 'releases the veil and restores the previous orientation' do
      before_state = Mnemosyne.aegis.dup
      previous = Mnemosyne.companion_veil(:owl, 'PERSONA')

      Mnemosyne.companion_release(previous)

      expect(Mnemosyne.aegis[:tags]).to eq(before_state[:tags])
      expect(Mnemosyne.aegis[:summary]).to eq(before_state[:summary])
      expect(Mnemosyne.aegis[:tags]).not_to include('facet:owl')
    end
  end
  describe 'suggestion empowerment (tools_for)' do
    ALL_TOOLS = { patch_file: 1, create_file: 1, rename_file: 1, read_file: 1,
                  run_command: 1, fenrir_suggest: 1, fenrir_say: 1,
                  fenrir_commit: 1, fenrir_ask: 1, owl_say: 1 }.freeze

    it 'keeps the scout set for a bare consult turn' do
      tools = CompanionPrograms.tools_for(:fenrir, all_tools: ALL_TOOLS)
      expect(tools).to include(:fenrir_suggest)
      expect(tools).not_to include(:patch_file, :create_file, :run_command)
    end

    it 'empowers the companion with the full core chain when a suggestion executes' do
      tools = CompanionPrograms.tools_for(:fenrir, all_tools: ALL_TOOLS, suggestion_execution: true)
      expect(tools).to include(:patch_file, :create_file, :rename_file, :run_command)
      expect(tools).to include(:fenrir_suggest, :fenrir_ask)
      expect(tools).not_to include(:owl_say)
    end
  end

  describe 'grant tiers (suggestion execution)' do
    it 'resolves spy, scribe and executor tiers from the recipe' do
      expect(CompanionPrograms.grant_for(:corax)[:write]).to be(false)
      expect(CompanionPrograms.grant_for(:owl)[:write]).to be(true)
      expect(CompanionPrograms.grant_for(:owl)[:confirm]).to eq([])
      expect(CompanionPrograms.grant_for(:fenrir)[:confirm]).to include('delete')
    end

    it 'defaults to spy for an unknown glyph' do
      expect(CompanionPrograms.grant_for(:unknown_glyph)[:write]).to be(false)
    end

    it 'withholds write tools from spy-tier companions' do
      tools = CompanionPrograms.tools_for(:corax, all_tools: ALL_TOOLS, suggestion_execution: true)
      expect(tools).not_to include(:patch_file, :create_file, :rename_file)
      expect(tools).to include(:read_file, :run_command)
    end

    it 'grants write tools to scribe-tier companions' do
      tools = CompanionPrograms.tools_for(:owl, all_tools: ALL_TOOLS, suggestion_execution: true)
      expect(tools).to include(:patch_file, :create_file, :rename_file)
    end

    it 'maps destructive verbs to concrete tool names' do
      expect(CompanionPrograms.confirm_tools(:fenrir)).to include(:remove_note, :remove_task,
                                                                 :rename_file, :create_file)
    end

    it 'requires confirmation only for executor-tier companions on destructive tools' do
      expect(CompanionPrograms.requires_confirmation?(:fenrir, :remove_note)).to be(true)
      expect(CompanionPrograms.requires_confirmation?(:owl, :remove_note)).to be(false)
      expect(CompanionPrograms.requires_confirmation?(:fenrir, :patch_file)).to be(false)
      expect(CompanionPrograms.requires_confirmation?(nil, :remove_note)).to be(false)
    end
  end
  describe %q{reach axis (advanced communication)} do
    ALL_COMM = { patch_file: 1, create_file: 1, rename_file: 1, read_file: 1, run_command: 1,
                 fenrir_suggest: 1, fenrir_say: 1, fenrir_commit: 1, fenrir_ask: 1,
                 owl_say: 1, corax_say: 1, corax_suggest: 1, corax_commit: 1,
                 drache_say: 1, drache_suggest: 1, drache_commit: 1,
                 metempsychosis: 1, create_task: 1, execute_task: 1, update_task: 1,
                 evaluate_task: 1, list_tasks: 1, remove_task: 1 }.freeze

    it %q{resolves the three seers from the recipes} do
      %i[owl corax drache].each { |g| expect(CompanionPrograms.reach_for(g)).to eq(:seer) }
      expect(CompanionPrograms.reach_for(:fenrir)).to eq(:local)
      expect(CompanionPrograms.reach_for(:unknown_glyph)).to eq(:local)
    end

    it %q{subtracts cross-context tools from local companions during suggestion execution} do
      tools = CompanionPrograms.tools_for(:fenrir, all_tools: ALL_COMM, suggestion_execution: true)
      expect(tools).not_to include(:metempsychosis, :create_task, :remove_task)
      expect(tools).to include(:patch_file)
    end

    it %q{keeps the æther for seer companions during suggestion execution} do
      tools = CompanionPrograms.tools_for(:drache, all_tools: ALL_COMM, suggestion_execution: true)
      expect(tools).to include(:metempsychosis, :create_task, :list_tasks)
      expect(tools).not_to include(:patch_file) # drache bleibt Späher-Stufe
    end

    it %q{gives a seer the æther even in a bare consult turn} do
      tools = CompanionPrograms.tools_for(:corax, all_tools: ALL_COMM)
      expect(tools).to include(:metempsychosis, :create_task)
      expect(tools).not_to include(:patch_file)
    end

    it %q{keeps local companions in the crystal for a bare consult turn} do
      tools = CompanionPrograms.tools_for(:kitsune, all_tools: ALL_COMM)
      expect(tools).not_to include(:metempsychosis, :create_task)
    end

    it %q{describes reach in the protocol prompt} do
      seer_prompt  = CompanionPrograms.build_system_prompt(:owl, %q{PERSONA})
      local_prompt = CompanionPrograms.build_system_prompt(:fenrir, %q{PERSONA})
      expect(seer_prompt).to include(%q{metempsychosis})
      expect(local_prompt).to include(%q{lokalen Kristall})
      expect(local_prompt).not_to include(%q{metempsychosis})
    end
  end
end
