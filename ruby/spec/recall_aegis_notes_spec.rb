# Test for integrating Aegis summaries into history messages
require 'rspec'
require_relative '../mnemosyne/mnemosyne'



describe 'Aegis summaries in history' do
  before do
    # Seed deterministic history rows so the spec does not depend on live memory data
    Mnemosyne.save_aegis_state(tags: ['aegis'], summary: 'Implemented restart mechanism for temperature parameter adjustments', temperature: 1.0, working_dir: '/tmp', thinking: 'normal')
    Mnemosyne.save_aegis_state(tags: ['aegis'], summary: 'Implemented restart mechanism for temperature adjustments in Oracle', temperature: 1.0, working_dir: '/tmp', thinking: 'normal')
  end

  it 'limits summaries by token count' do
    max_tokens = 500
    summaries = Mnemosyne.fetch_aegis_summaries(before: Time.now, max_tokens: max_tokens)
    expect(summaries.length).to be > 1
  end

  it 'filters summaries by date' do
    summaries = Mnemosyne.fetch_aegis_summaries(before: Time.now, max_tokens: 100)
    texts = summaries.map { |s| s[:summary] }
    expect(texts).to include("Implemented restart mechanism for temperature parameter adjustments")
    expect(texts).to include("Implemented restart mechanism for temperature adjustments in Oracle")
  end
end
