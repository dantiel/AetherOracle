# frozen_string_literal: true

require 'rspec'
require 'json'
require_relative '../oracle/artificer'

RSpec.describe 'Artificer.extract_instrumenta_from_content' do
  let(:artificer) { Artificer }

  # Helper to load fixture
  def load_fixture(name)
    path = File.join(File.dirname(__FILE__), 'fixtures', name)
    JSON.parse(File.read(path))
  end

  # Helper to normalize tool for comparison
  def normalize_tool(tool)
    {
      'id' => tool['id'],
      'type' => tool['type'] || 'function',
      'function' => {
        'name' => tool.dig('function', 'name') || tool['name'],
        'arguments' => tool.dig('function', 'arguments') || tool['arguments']
      }
    }
  end

  describe 'JSON in markdown fences' do
    let(:fixtures) { load_fixture('tool_call_json_markdown.json') }

    it 'extracts standard JSON tool calls from markdown fences' do
      fixture = fixtures[0]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      expect(result.first['id']).to eq('call_123')
      expect(result.first.dig('function', 'name')).to eq('read_file')
    end

    it 'extracts multiple tools from single JSON block' do
      fixture = fixtures[1]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(2)
      expect(result.map { |t| t.dig('function', 'name') }).to contain_exactly('read_file', 'run_command')
    end
  end

  describe 'XML invoke blocks (GLM-5 style)' do
    let(:fixtures) { load_fixture('tool_call_xml_invoke.json') }

    it 'extracts tool calls from XML invoke blocks' do
      fixture = fixtures[0]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      expect(result.first.dig('function', 'name')).to eq('read_file')
      
      args = JSON.parse(result.first.dig('function', 'arguments'))
      expect(args['path']).to eq('config.rb')
    end

    it 'extracts multiple XML invoke blocks' do
      fixture = fixtures[1]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(2)
      expect(result.map { |t| t.dig('function', 'name') }).to contain_exactly('run_command', 'read_file')
    end
  end

  describe 'Inline JSON extraction' do
    let(:fixtures) { load_fixture('tool_call_inline.json') }

    it 'extracts inline JSON with tool_calls key' do
      fixture = fixtures[0]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      expect(result.first.dig('function', 'name')).to eq('patch_file')
    end

    it 'extracts inline JSON array starting with tool object' do
      fixture = fixtures[1]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      expect(result.first.dig('function', 'name')).to eq('read_file')
    end

    it 'handles nested JSON with escaped quotes in arguments' do
      fixture = fixtures[2]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      
      args = JSON.parse(result.first.dig('function', 'arguments'))
      expect(args['cmd']).to include('echo')
    end
  end

  describe 'Nested and complex structures' do
    let(:fixtures) { load_fixture('tool_call_nested.json') }

    it 'extracts from deeply nested JSON' do
      fixture = fixtures[0]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      expect(result.first['id']).to eq('deep')
    end

    it 'handles array inside object inside array' do
      fixture = fixtures[1]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
    end

    it 'parses JSON with nested braces in arguments string' do
      fixture = fixtures[2]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      
      args = JSON.parse(result.first.dig('function', 'arguments'))
      expect(args['path']).to eq('app.rb')
      expect(args['content']).to include('def foo')
    end
  end

  describe 'Edge cases and error handling' do
    let(:fixtures) { load_fixture('tool_call_edge_cases.json') }

    it 'returns empty array for empty tool_calls' do
      fixture = fixtures[0]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result).to eq([])
    end

    it 'handles malformed JSON gracefully' do
      fixture = fixtures[1]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      # Should not raise, should return empty or partial
      expect(result).to be_an(Array)
    end

    it 'filters invalid tool objects' do
      fixture = fixtures[2]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      expect(result.first['id']).to eq('good')
    end

    it 'handles arguments as object instead of JSON string' do
      fixture = fixtures[3]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
      # Arguments should be converted to JSON string
      args = result.first.dig('function', 'arguments')
      expect { JSON.parse(args) }.not_to raise_error
    end

    it 'deduplicates by ID' do
      fixture = fixtures[4]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
    end

    it 'deduplicates by name+arguments combination' do
      fixture = fixtures[5]
      result = artificer.extract_instrumenta_from_content(fixture['input'])
      
      expect(result.length).to eq(fixture['expected_count'])
    end
  end

  describe 'Mixed format extraction' do
    it 'extracts from mixed JSON and XML formats' do
      input = <<~MIXED
        First, read the file:
        ```json
        {"tool_calls": [{"id": "json_1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]}
        ```
        Then run command:
        <invoke name="run_command">
        <parameter name="cmd">ls</parameter>
        </invoke>
      MIXED
      
      result = artificer.extract_instrumenta_from_content(input)
      
      expect(result.length).to eq(2)
      expect(result.map { |t| t.dig('function', 'name') }).to contain_exactly('read_file', 'run_command')
    end

    it 'extracts from text with multiple inline JSON objects' do
      input = 'Tool 1: {"name": "read_file", "arguments": "{}"} and Tool 2: {"name": "run_command", "arguments": "{\\"cmd\\": \\"pwd\\"}"}'
      
      result = artificer.extract_instrumenta_from_content(input)
      
      expect(result.length).to be >= 2
    end
  end

  describe 'Performance and limits' do
    it 'handles large input efficiently' do
      # Generate large input with 100 tool calls
      tools = 100.times.map do |i|
        { id: "tool_#{i}", type: 'function', function: { name: 'read_file', arguments: '{}' } }
      end
      input = "{\"tool_calls\": #{tools.to_json}}"
      
      start_time = Time.now
      result = artificer.extract_instrumenta_from_content(input)
      elapsed = Time.now - start_time
      
      expect(result.length).to eq(100)
      expect(elapsed).to be < 1.0 # Should complete in under 1 second
    end

    it 'handles deeply nested structures without stack overflow' do
      # Create deeply nested JSON
      nested = 50.times.reduce({ 'name' => 'read_file' }) { |acc, _| { 'data' => acc } }
      input = nested.to_json
      
      expect { artificer.extract_instrumenta_from_content(input) }.not_to raise_error
    end
  end
end
