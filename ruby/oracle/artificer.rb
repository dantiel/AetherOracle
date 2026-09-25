# frozen_string_literal: true

require_relative 'error_handler'
require_relative '../instrumentarium/hermetic_execution_domain'
require_relative '../instrumentarium/vision_coordinator'

# Instrumentator provides hermetic, side-effect-free execution of instrumenta
# with proper message handling and error management. Designed for reuse across the system.
# Now with vision support via VisionCoordinator for screenshot analysis.
class Artificer
  TOOL_CALLS_ALIASES = {
    'toolcalls'  => 'tool_calls',
    'tools'      => 'tool_calls',
    'tool_name'  => 'name',
    'toolname'   => 'name',
    'args'       => 'arguments',
    'params'     => 'arguments',
    'parameters' => 'arguments'
  }.freeze



  # Exception to signal restart needed
  class RestartException < StandardError; end



  class << self
    # Execute a standard instrumenta call with hermetic principles
    # Returns [result, updated_messages, updated_tool_results]
    def execute_standard(instrumenta_call, messages, instrumenta_results, sink: nil, &execution_block)
      id = instrumenta_call['id']
      name = extract_instrumenta_name instrumenta_call
      args = extract_instrumenta_arguments instrumenta_call

      log_instrumenta_call 'INSTRUMENTA_CALL', name, args
      safe_context = create_safe_context instrumenta_results
      start_time = Time.now
      tool_uuid = SecureRandom.uuid
      Thread.current[:aether_tool_uuid] = tool_uuid
      sink&.send_status 'tool_starting', { name:, args: echo_args(args) }, uuid: tool_uuid

      result = HermeticExecutionDomain.execute max_retries: 2, timeout: 86_400 do
        exec_result = execution_block.call name, args, safe_context
        exec_time = Time.now - start_time

        if exec_result.is_a?(Hash) && exec_result.key?(:__divine_interrupt)
          # Return the divine-interruption sentinel as the block's *normal* value.
          # A `break` here escapes the proc when HermeticExecutionDomain runs the
          # block inside its lease thread, raising `LocalJumpError: break from
          # proc-closure` and silently discarding the step-completion signal —
          # which is exactly how task steps used to fail with NO_COMPLETION_SIGNAL.
          next [:__divine_interrupt, exec_result, messages, instrumenta_results, nil]
        end

        safe_result = safe_encode exec_result
        sink&.send_status 'tool_completed', { name:, execution_time: exec_time, result: ui_preview(safe_result, name: name) }, uuid: tool_uuid
        updated_instrumenta_results = instrumenta_results + [{ id:, name:, result: safe_result, args:, execution_time: exec_time.round(3) }]

        # Build tool message and vision message separately.
        # Vision messages (user role with image) MUST NOT be interleaved between
        # tool messages — DeepSeek requires assistant(tool_calls) → tool → tool
        # with no user messages breaking the chain. Vision is appended after
        # all tool messages in execute_instrumenta_calls.
        tool_message = { role: 'tool', tool_call_id: id, content: safe_result.to_json }
        vision_message = build_vision_user_message(result: exec_result)

        [exec_result, messages + [tool_message], vision_message, updated_instrumenta_results]
      end

      if result.is_a?(Array) && result.first == :__divine_interrupt
        return [result[1], result[2], result[3], result[4]]
      end

      result
    rescue HermeticExecutionDomain::Error => e
      handle_hermetic_execution_error e, 'Hermetic execution failed'
    end


    # Execute a fallback instrumenta call with hermetic principles
    # Returns [result, updated_messages, updated_tool_results]
    def execute_fallback(instrumenta_call, messages, instrumenta_results, sink: nil, &execution_block)
      name = instrumenta_call[:name]
      log_instrumenta_call 'FALLBACK_INSTRUMENTA_CALL', name,
                           instrumenta_call[:args]
      safe_context = create_safe_context instrumenta_results
      start_time = Time.now
      tool_uuid = SecureRandom.uuid
      Thread.current[:aether_tool_uuid] = tool_uuid
      sink&.send_status 'tool_starting', { name:, args: echo_args(instrumenta_call[:args]) }, uuid: tool_uuid

      result = HermeticExecutionDomain.execute max_retries: 2, timeout: 86_400 do
        exec_result = execution_block.call name, instrumenta_call[:args], safe_context
        exec_time = Time.now - start_time

        if exec_result.is_a?(Hash) && exec_result.key?(:__divine_interrupt)
          next [:__divine_interrupt, exec_result, messages, instrumenta_results, nil]
        end

        safe_result = safe_encode exec_result
        sink&.send_status 'tool_completed', { name:, execution_time: exec_time, result: ui_preview(safe_result, name: name) }, uuid: tool_uuid
        instrumenta_call_id = instrumenta_call[:id] || SecureRandom.uuid
        updated_instrumenta_results = instrumenta_results + [{ id:     instrumenta_call_id,
                                                               name:,
                                                               result: safe_result,
                                                               args:   instrumenta_call[:args],
                                                               execution_time: exec_time.round(3) }]

        tool_message = { role: 'tool', tool_call_id: instrumenta_call_id, content: safe_result.to_json }
        vision_message = build_vision_user_message(result: exec_result)
        [exec_result, messages + [tool_message], vision_message, updated_instrumenta_results]
      end

      if result.is_a?(Array) && result.first == :__divine_interrupt
        return [result[1], result[2], result[3], result[4]]
      end

      result
    rescue HermeticExecutionDomain::Error => e
      handle_hermetic_execution_error e, 'Hermetic execution failed'
    end



    # Handle multiple instrumenta calls in sequence with proper message accumulation
    # Returns [results, updated_messages, updated_tool_results]
    def execute_instrumenta_calls(instrumenta_calls,
                                  messages,
                                  instrumenta_results,
                                  content,
                                  sink: nil,
                                  &exec_call)
      instrumenta_results << { content: }
      vision_messages = []
      results, final_messages, final_tool_results = instrumenta_calls.reduce [[], messages, instrumenta_results] do
      |(results, current_messages, prev_instrumenta_results), instrumenta_call|
        result, new_messages, vision_msg, new_instrumenta_results =
          execute_standard(instrumenta_call, current_messages, prev_instrumenta_results, sink:, &exec_call)
        vision_messages << vision_msg if vision_msg
        [results + [result], new_messages, new_instrumenta_results]
      end

      # Append all vision user messages AFTER all tool messages to avoid
      # breaking the DeepSeek-enforced chain: assistant(tool_calls) → tool → tool
      final_messages += vision_messages if vision_messages.any?

      [results, final_messages, final_tool_results]
    end


    # Handle multiple fallback instrumenta calls in sequence
    # Returns [results, updated_messages, updated_tool_results]
    def execute_fallback_instrumenta_calls(instrumenta_calls,
                                           messages,
                                           instrumenta_results,
                                           sink: nil,
                                           &execution_block)
      vision_messages = []
      results, final_messages, final_tool_results = instrumenta_calls.reduce [[], messages,
                                instrumenta_results] do |(results, current_messages, prev_instrumenta_results), instrumenta_call|
        result, new_messages, vision_msg, new_instrumenta_results = execute_fallback(instrumenta_call,
                                                                         current_messages, prev_instrumenta_results, sink:, &execution_block)
        vision_messages << vision_msg if vision_msg
        [results + [result], new_messages, new_instrumenta_results]
      end

      final_messages += vision_messages if vision_messages.any?

      [results, final_messages, final_tool_results]
    end


    def extract_instrumenta_name(instrumenta_call)
      instrumenta_call['name'] || instrumenta_call[:name] ||
        instrumenta_call.dig('function', 'name') || instrumenta_call.dig(:function, :name)
    end


    def extract_raw_arguments(instrumenta_call)
      instrumenta_call['arguments'] || instrumenta_call[:arguments] ||
        instrumenta_call.dig('function', 'arguments') || instrumenta_call.dig(:function, :arguments)
    end


    def extract_instrumenta_arguments(instrumenta_call)
      args = extract_raw_arguments(instrumenta_call) || {}

      args = ensure_json(args) if args.is_a? String
      args.transform_keys(&:to_sym)
    end


    # Serialise a tool call's arguments for the live UI echo. The Swift file
    # mirror decodes these back into structured `ReadFileArgs` / `PatchFileArgs`
    # (path, range, diff, …) — so they must travel as *JSON*, never Ruby's
    # `Hash#to_s` dump (`{:path=>"…"}`), which Swift's JSONDecoder cannot read.
    def echo_args(args)
      return '{}' if args.nil?
      return args if args.is_a?(String)
      args.to_json
    rescue StandardError
      args.to_s
    end


    # Detects truncated/malformed tool-call argument JSON before execution.
    # The OpenAI tool_call `arguments` field is a raw JSON string; when the model
    # hits max_tokens mid-generation the string ends abruptly and JSON.parse fails.
    # Executing such a call with `{}` (via ensure_json's silent fallback) would lose
    # the step result, so the divination loop retries instead.
    def tool_calls_arguments_valid?(tool_calls)
      Array(tool_calls).all? do |call|
        args = extract_raw_arguments(call)
        next true unless args.is_a?(String) && !args.strip.empty?

        JSON.parse(args)
        true
      rescue JSON::ParserError
        false
      end
    end


    def extract_instrumenta_from_content(text)
      return [] unless text.present?

      all_tools = []

      # 1. JSON blocks in markdown fences (```json ... ```)
      jsons = text.scan(/^\s*```json\s*\n(.*?)^\s*```/m)
      all_tools += jsons.hermetic_map do |json_match|
        json_text = json_match[0]
        obj = parse_json_safely json_text
        extract_instrumenta_from_parsed_object obj
      end.flatten.compact

      # 2. XML <invoke> blocks (GLM-5 and similar models)
      all_tools += extract_xml_invoke_tool_calls(text)

      # 3. Inline JSON objects with tool_calls key
      # Matches patterns like: {"tool_calls": [...]}
      inline_tool_calls = text.scan(/\{[^{}]*"tool_calls"\s*:\s*\[[^\]]+\][^{}]*\}/m)
      all_tools += inline_tool_calls.hermetic_map do |json_str|
        obj = parse_json_safely json_str
        extract_instrumenta_from_parsed_object obj
      end.flatten.compact

      # 4. Inline JSON arrays starting with tool-like objects
      # Matches: [{"name": "...", "arguments": "..."}]
      inline_arrays = text.scan(/\[\s*\{[^{}]*"name"\s*:\s*"[^"]+"\s*,\s*"arguments"\s*:/m)
      all_tools += inline_arrays.hermetic_map do |json_start|
        # Find the full array by parsing from the opening bracket
        full_json = extract_full_json_array(json_start, text)
        next [] unless full_json
        
        obj = parse_json_safely full_json
        obj.is_a?(Array) ? obj.map { |tool| extract_instrumenta_from_parsed_object(tool) } : []
      end.flatten.compact

      # 5. Extract JSON objects/arrays with proper brace matching
      # This catches inline tool calls without markdown fences
      # Track processed positions to avoid duplicate extraction
      processed_ranges = Set.new
      
      text.scan(/\{/) do
        start_pos = $~.begin(0)
        
        # Skip if this position is already inside a processed range
        next if processed_ranges.any? { |range| range.include?(start_pos) }
        
        json_obj = extract_json_at_position(start_pos, text)
        next unless json_obj
        
        end_pos = start_pos + json_obj.length - 1
        
        # Mark this range as processed
        processed_ranges << (start_pos..end_pos)
        
        obj = parse_json_safely(json_obj)
        next unless obj.is_a?(Hash)
        
        tools = extract_instrumenta_from_parsed_object(obj) || []
        
        # Check if obj itself is a tool call - STRICTER VALIDATION
        if tools.empty?
          # Only accept as tool if it has 'type' OR complete 'name'+'arguments' pair
          has_type = obj['type']
          has_complete_tool = obj['name'] && obj['arguments']
          has_function_tool = obj['function']&.dig('name') && obj['function']&.dig('arguments')
          
          if has_type || has_complete_tool || has_function_tool
            normalized = obj.transform_keys { |k| TOOL_CALLS_ALIASES.safe_get(k) || k }
            
            # Normalize to standard function format if needed
            if normalized['name'] && !normalized['function']
              normalized = {
                'id' => normalized['id'],
                'type' => 'function',
                'function' => {
                  'name' => normalized['name'],
                  'arguments' => normalized['arguments']
                }
              }
            end
            
            tools = [normalized]
          end
        end
        all_tools += tools if tools.any?
      end
      
      text.scan(/\[/) do
        start_pos = $~.begin(0)
        
        # Skip if this position is already inside a processed range
        next if processed_ranges.any? { |range| range.include?(start_pos) }
        
        json_arr = extract_json_at_position(start_pos, text)
        next unless json_arr
        
        end_pos = start_pos + json_arr.length - 1
        
        # Mark this range as processed
        processed_ranges << (start_pos..end_pos)
        
        arr = parse_json_safely(json_arr)
        next unless arr.is_a?(Array)
        
        arr.each do |item|
          next unless item.is_a?(Hash)
          
          tools = extract_instrumenta_from_parsed_object(item) || []
          
          # Check if item itself is a tool call - STRICTER VALIDATION
          if tools.empty?
            has_type = item['type']
            has_complete_tool = item['name'] && item['arguments']
            has_function_tool = item['function']&.dig('name') && item['function']&.dig('arguments')
            
            if has_type || has_complete_tool || has_function_tool
              normalized = item.transform_keys { |k| TOOL_CALLS_ALIASES.safe_get(k) || k }
              
              # Normalize to standard function format if needed
              if normalized['name'] && !normalized['function']
                normalized = {
                  'id' => normalized['id'],
                  'type' => 'function',
                  'function' => {
                    'name' => normalized['name'],
                    'arguments' => normalized['arguments']
                  }
                }
              end
              
              tools = [normalized]
            end
          end
          all_tools += tools if tools.any?
        end
      end

      # Deduplicate by id, or by name+arguments combination
      all_tools.uniq do |t|
        t['id'] || "#{t['name'] || t['function']&.dig('name')}:#{t['arguments'] || t['function']&.dig('arguments')}"
      end
    end

    # Extract JSON object or array from text starting at position
    # Handles nested structures and escaped quotes
    def extract_json_at_position(start_pos, text)
      opening_char = text[start_pos]
      return nil unless opening_char == '{' || opening_char == '['
      
      closing_char = opening_char == '{' ? '}' : ']'
      bracket_count = 0
      in_string = false
      escape_next = false
      
      (start_pos...text.length).each do |i|
        char = text[i]
        
        if escape_next
          escape_next = false
          next
        end
        
        case char
        when '\\'
          escape_next = true
        when '"'
          in_string = !in_string
        when '{', '['
          bracket_count += 1 unless in_string
        when '}', ']'
          bracket_count -= 1 unless in_string
          if bracket_count == 0 && char == closing_char
            return text[start_pos..i]
          end
        end
      end
      
      nil
    end


    private


    def log_tool_call(type, name, args)
      puts "[ORACLE][#{type}]: #{name} with args: #{args.to_s.truncate 100}"
    rescue StandardError => e
      HorologiumAeternum.system_error "Failed to log tool call: #{e.message.truncate 100}"
    end


    def extract_instrumenta_from_parsed_object(parsed_object)
      if parsed_object['tool_calls']
        parsed_object['tool_calls'].hermetic_map do |tool|
          normalized = tool.transform_keys { |key| TOOL_CALLS_ALIASES.safe_get(key) || key }
          # Filter: only accept type='function' or missing type (backward compatibility)
          next nil unless normalized['type'].nil? || normalized['type'] == 'function'
          
          # Normalize arguments to JSON string if it's a Hash
          if normalized['function'] && normalized['function']['arguments'].is_a?(Hash)
            normalized['function']['arguments'] = normalized['function']['arguments'].to_json
          end
          
          normalized
        end.compact
      elsif parsed_object.keys.any? { |key| TOOL_CALLS_ALIASES.key? key }
        normalized = parsed_object.transform_keys { |key| TOOL_CALLS_ALIASES.safe_get(key) || key }
        
        # Normalize arguments to JSON string if it's a Hash
        if normalized['function'] && normalized['function']['arguments'].is_a?(Hash)
          normalized['function']['arguments'] = normalized['function']['arguments'].to_json
        end
        
        normalized
      end
    end


    # Helper methods for JSON parsing
    def parse_json_safely(json_text)
      JSON.parse json_text
    rescue StandardError
      {}
    end


    def ensure_json(raw)
      return raw if raw.is_a? Hash

      clean = clean_json_raw raw
      JSON.parse clean
    rescue JSON::ParserError => e
      repaired = repair_json_quotes(clean) || {}
      return repaired unless repaired.empty?

      log_json_parse_error e, clean
      {}
    end

    def clean_json_raw(raw)
      clean = (raw.respond_to?(:dup) ? raw.dup : raw.to_s)
      clean.force_encoding('UTF-8') if clean.encoding == Encoding::ASCII_8BIT
      clean.valid_encoding? ? clean : clean.scrub
    end

    def log_json_parse_error(error, clean)
      col = error.message[/column (\d+)/, 1]&.to_i
      snippet = col ? clean.to_s[[col - 40, 0].max..col + 40] : clean.to_s.truncate(200)
      HorologiumAeternum.system_error 'Failed to parse tool arguments JSON',
                                      message: "#{error.message.truncate(190)} | near: …#{snippet}…"
    end

    # Repair JSON with unescaped quotes inside string values.
    def repair_json_quotes(json_str)
      return nil unless json_str.is_a?(String) && json_str.start_with?('{')

      fixed = json_str.gsub(/(?<=[^\\])"(?=[^,}\]:\s])/) { '\\"' }
      return nil if fixed == json_str

      JSON.parse fixed
    rescue JSON::ParserError
      nil
    end

    # Extract tool calls from XML <invoke> blocks (GLM-5 compatibility)
    def extract_xml_invoke_tool_calls(text)
      # Match <invoke name="tool_name"> blocks with <parameter name="param">value</parameter>
      invoke_pattern = /<invoke\s+name\s*=\s*['"]([^'"]+)['"]\s*>(.*?)<\/invoke>/m
      param_pattern = /<parameter\s+name\s*=\s*['"]([^'"]+)['"]\s*>(.*?)<\/parameter>/m

      text.scan(invoke_pattern).hermetic_map do |tool_name, invoke_body|
        args = {}
        invoke_body.scan(param_pattern) do |param_name, param_value|
          args[param_name] = param_value.strip
        end

        {
          'id' => "xml_invoke_#{SecureRandom.hex(4)}",
          'type' => 'function',
          'function' => {
            'name' => tool_name,
            'arguments' => args.to_json
          }
        }
      end.compact
    rescue StandardError => e
      HorologiumAeternum.system_error "Failed to parse XML invoke blocks: #{e.message.truncate(100)}"
      []
    end


    def log_instrumenta_call(type, name, args)
      puts "[INSTRUMENTATOR][#{type}]: #{name} with args: #{args.to_s.truncate 100}"
    end


    def create_safe_context(tool_results)
      { tool_results: tool_results.dup.freeze }
    end


    def handle_hermetic_execution_error(error, _message)
      # Don't log here - the error will be caught and handled by the calling context
      raise error
    end


    # Recursively encode strings to UTF-8, replacing invalid bytes
    def safe_encode(value)
      case value
      when String then value.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      when Hash   then value.transform_values { |v| safe_encode v }
      when Array  then value.map { |v| safe_encode v }
      else value
      end
    end

    # Compact, human-readable echo of a tool result for the live UI stream. The
    # full result still reaches the model via the tool message; this is only what
    # the Pythia panel renders. truncate_tool_output already bounds results, so
    # capping here is purely cosmetic.
    def ui_preview(result, limit = 4000, name: nil)
      # read_file/file_overview behalten ihre Struktur, damit die Swift-Datei-Spiegel
      # (Pfad/Range/Inhalt bzw. Datei-Übersicht) das Ergebnis als JSON dekodieren
      # können; andere content-tragende Ergebnisse bleiben ein kompaktes Echo.
      return result if %w[read_file file_overview].include?(name&.to_s) && result.is_a?(Hash)

      text = if result.is_a?(Hash)
               (result[:content] || result['content'] || result.to_json).to_s
             else
               result.to_s
             end
      text.truncate(limit)
    end

    # Build user message with screenshot image for vision models
    # Returns nil if no images found, or a user message with image content
    def build_vision_user_message(result:)
      image_refs = VisionCoordinator.extract_image_references(result)
      return nil if image_refs.empty?

      image_attachments = image_refs.map { |ref| VisionCoordinator.load_and_encode(ref) }.compact
      return nil if image_attachments.empty?

      # Build content array with text preamble + images
      content_parts = [
        { type: 'text', text: 'Screenshot captured for visual analysis:' }
      ]

      image_attachments.each do |img|
        if img[:error]
          content_parts << { type: 'text', text: "[Image error: #{img[:error]}]" }
        else
          content_parts << {
            type: 'image_url',
            image_url: { url: img[:data_uri] }
          }
        end
      end

      { role: 'user', content: content_parts }
    end
  end
end