# frozen_string_literal: true

require 'bundler/setup'
require 'time'
require 'fileutils'
require 'timeout'
require 'socket'
require 'digest'
require_relative '../argonaut/temp_file_manager'
require_relative '../instrumentarium/hermetic_execution_domain'
require_relative '../instrumentarium/horologium_aeternum'
require_relative '../instrumentarium/metaprogramming_utils'
require_relative '../mnemosyne/mnemosyne'
require_relative 'artificer'
require_relative 'conduit'
require_relative 'coniunctio'
require_relative 'error_handler'
using TokenExtensions


def log_json(**kwargs)
  if kwargs.key? :json
    # Debug logging — silenced in production
  else
    # Handle error logging format
    message = '[ORACLE][ERROR]: '
    message += "error: #{kwargs[:error].to_s.truncate 600}" if kwargs[:error]
    if kwargs.key? :backtrace
      message += ", backtrace: #{kwargs[:backtrace].first(3).join(' | ').truncate 600}"
    end
    message += ", info: #{kwargs[:info].to_s.truncate 600}" if kwargs[:info]
    puts message
  end
end



using MetaprogrammingUtils



# Hermetic Oracle for AI-assisted coding with functional purity
class Oracle
  SYSTEM_PROMPT = File.read "#{__dir__}/aether_codex.system_instructions.md"
  REASONING_PROMPT = File.read "#{__dir__}/aether_codex.reasoning_instructions.md"
  SYSTEM_PROMPT_BRIEFING = <<~BRIEFING
    Focus on autonomous execution: Read files, plan briefly if needed, then chain all required tools
    (e.g., read_file → recall_notes → patch) in one go. Do not seek confirmation—apply changes and
    proceed to verify (e.g., run tests) without pausing. Prioritize precision and action over
    dialogue. !!DONT OUTPUT JSON IN CONTENT!! Do what you have been asked. Just do it.
  BRIEFING
  FLASH_AUTO_REMINDER = <<~REMINDER
    ⚡ FLASH MODE (one-shot): This request runs on the fast model — the persistent Aegis thinking depth was temporarily bypassed and will revert when this turn ends. You have full tool access and can investigate, create tasks, or respond directly. If deeper reasoning is needed, call `aegis(thinking: "normal")` (or "high"/"max") to switch persistently. For precision work, `aegis(temperature: 0.0)`. You decide — there is no pre-programmed path.
  REMINDER
  TEMPERATURE_DELTA_THRESHOLD = 0.2
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

  # Exception to signal step completion/rejection - terminates current reasoning
  class StepTerminationException < StandardError; end

  # Class variables for reminder system
  @@reminder_store = {}
  @@reminder_counter = 0


  class << self
    # Store a reminder to prevent divination exit
    def store_reminder(session_id, reminder_message)
      @@reminder_store[session_id] ||= []
      @@reminder_store[session_id] << {
        id:        @@reminder_counter += 1,
        message:   reminder_message,
        timestamp: Time.now
      }
      # Keep only last 5 reminders per session
      @@reminder_store[session_id] = @@reminder_store[session_id].last 5
    end


    # Get all reminders for a session
    def get_reminders(session_id)
      @@reminder_store[session_id] || []
    end


    # Clear reminders for a session
    def clear_reminders(session_id)
      @@reminder_store.delete session_id
    end


    # Public API Methods
    def ask(prompt, context)
      divination(prompt, context, tools: nil) do |name, args|
        PrimaMateria.handle(tool: name, args:, context:)
      end
        .then { |a, arts, _| [a, arts] }
    end


    def divination(prompt_or_messages,
                   context,
                   tools: nil,
                   system_prompt: nil,
                   stream: nil,
                   max_depth: 180,
                   reasoning: false,
                   msg_uuid: nil,
                   resume_state: nil,
                   &exec)
      # Create and enter temp file context for this oracle execution
      temp_context_id = Argonaut::TempFileManager.create_context
      Argonaut::TempFileManager.enter_context temp_context_id

      # One-shot flash override — previous thinking is restored in the ensure block
      # unless the oracle set a new level (aegis tool) or a task took over.
      flash_previous_thinking = nil
      flash_override_applied = false

      set_temperature = set_temperature_from_context context
      
      if resume_state
        # Resume from saved state — use saved messages, tool_results, arts
        messages = resume_state[:messages] || base_messages(prompt_or_messages, context, reasoning, system_prompt)
        tool_results = resume_state[:tool_results] || []
        arts = resume_state[:arts] || { prelude: [] }
        (stream || HorologiumAeternum).thinking 'Resuming oracle from saved state...'
      else
        messages = base_messages prompt_or_messages, context, reasoning, system_prompt
        tool_results = []
        arts = { prelude: [] }

        # Flash one-shot: skip this request to the fast model regardless of Aegis.
        # We set the in-memory level (not persisted) and restore it afterwards.
        flash_auto = context.dig(:extra_context, :flash_auto)
        if flash_auto && Mnemosyne.aegis[:thinking] != 'fast'
          flash_previous_thinking = Mnemosyne.aegis[:thinking]
          flash_override_applied = true
          Mnemosyne.aegis[:thinking] = 'fast'
          # Insert reminder just before the user message (always last)
          messages.insert(-1, { role: 'system', content: FLASH_AUTO_REMINDER })
        end
      end

      # Track divination start time for thinking time calculation
      arts[:divination_start_time] = Time.now

      # Save initial state before entering loop — enables resume even before first API call
      Thread.current[:pause_state] = {
        messages: messages,
        tool_results: tool_results,
        arts: arts,
        answer: nil
      }

      stream_initial_status msg_uuid, stream, set_temperature

      result = execute_divination_loop(messages, tools, reasoning, tool_results, arts, set_temperature,
                                       context[:prevent_termination_reminder], max_depth, msg_uuid, stream, &exec)

      # Check if we got a divine interruption signal instead of a regular answer
      if result.is_a?(Hash) && result.key?(:__divine_interrupt)
        # Return the divine interruption signal directly (just the hash, not the array)
        return [result || '<<empty>>', arts, tool_results]
      end

      [result || '<<empty>>', arts, tool_results]
    rescue Oracle::RestartException => e
      raise Oracle::RestartException, (ErrorHandler.handle_restart_exception e)
    rescue StandardError => e
      ErrorHandler.handle_divination_error e, tool_results
    ensure
      # One-shot flash revert: restore the prior thinking level unless the oracle
      # explicitly changed it (aegis tool) or a task set its own reasoning depth.
      if flash_override_applied && Mnemosyne.aegis[:thinking] == 'fast'
        Mnemosyne.aegis[:thinking] = flash_previous_thinking || 'normal'
      end
      # Clean up temp file context for this oracle execution
      if defined?(Argonaut::TempFileManager) && temp_context_id
        Argonaut::TempFileManager.cleanup_context temp_context_id
        Argonaut::TempFileManager.exit_context
      end
    end


    def execute_divination_loop(messages,
                                tools,
                                reasoning,
                                tool_results,
                                arts,
                                set_temperature,
                                prevent_termination_reminder,
                                max_depth,
                                msg_uuid,
                                stream = nil,
                                attachments: nil,
                                &exec)
      answer = nil
      reminder = nil

      # puts "[ORACLE][DIVINATION_LOOP]: Reasoning mode: #{reasoning}"

      empty_responses = 0
      malformed_retries = 0

      (1..max_depth).each do |depth|
        # Always save current state before API call — enables resume even mid-API-call
        Thread.current[:pause_state] = {
          messages: messages,
          tool_results: tool_results,
          arts: arts,
          answer: answer
        }

        # Check for pause signal — cooperative interruption
        if Thread.current[:paused]
          return { __divine_interrupt: true, __reason: :paused }
        end

        thinking_before_api = Mnemosyne.aegis[:thinking]
        json = Conduit.generate_ai_response [*messages, reminder].compact, tools, reasoning,
                                            set_temperature
        content, tcalls, arts = Conduit.extract_response_data json, arts

        # puts "[ORACLE][DIVINATION_LOOP]: Response content: #{content.to_s.truncate(100)}"

        # Empty response guard: retry up to 3 times when LLM produces nothing
        if content.blank? && tcalls.empty?
          empty_responses += 1
          if empty_responses < 3
            HorologiumAeternum.system_error "Empty response — retrying (#{empty_responses}/3)"
            sleep 3 * (2**(empty_responses - 1))
            messages << { role: 'assistant', content: '<<empty>>' }
            messages << { role: 'user', content: 'Your previous response was empty. The system is retrying — please provide output this time.' }
            next
          end
          HorologiumAeternum.system_error "Empty response after #{empty_responses} retries — surrendering"
        else
          empty_responses = 0
        end

        # Malformed tool-arguments guard: when a tool call's JSON arguments were
        # truncated (max_tokens cut the generation mid-string), executing it would
        # silently drop the result (ensure_json falls back to {}). Retry instead.
        if tcalls.any? && !Artificer.tool_calls_arguments_valid?(tcalls)
          malformed_retries += 1
          if malformed_retries < 3
            HorologiumAeternum.system_error "Malformed tool arguments — retrying (#{malformed_retries}/3)"
            sleep 2**malformed_retries
            messages << { role: 'assistant', content: content.present? ? content : '<<truncated tool call>>' }
            messages << { role: 'user', content: 'Your last tool call had truncated/invalid JSON arguments. Re-issue the tool call with complete, valid JSON arguments.' }
            next
          end
          HorologiumAeternum.system_error "Malformed tool arguments after #{malformed_retries} retries — surrendering"
        else
          malformed_retries = 0
        end

        # Track when first content is received for thinking time calculation
        if content.present? && !arts[:first_content_time]
          arts[:first_content_time] = Time.now
          thinking_time = (Time.now - arts[:divination_start_time] || Time.now).round(2)
          model_icon = 'fast' == thinking_before_api ? '⚡' : '🧠'
          (stream || HorologiumAeternum).send_status('thinking_complete',
                                                     { thinking_time:, model_icon: },
                                                     uuid: msg_uuid)
          msg_uuid = nil
        end

        messages << (add_assistant_message messages, content, tcalls, arts)
        arts = collect_prelude_content arts, content
        stream_reasoning_content arts

        # In reasoning mode, we should NOT process tool calls - reasoning models only provide reasoning
        unless reasoning
          tool_call_result = process_tool_calls tcalls, messages, tool_results, content, exec, arts, stream

          # Check if tool call returned a divine interruption signal
          if tool_call_result.is_a?(Hash) && tool_call_result.key?(:__divine_interrupt)
            return tool_call_result
          end

          if true == tool_call_result
            next
          end
        end
        
        # Check for prevent_termination_reminder in context - add reminder if present
        if prevent_termination_reminder&.any?
          reminders = prevent_termination_reminder
          reminder = reminders.last

          if reminder
            prevent_termination_reminder = reminders.drop 1
            next
          end
        end
        
        answer = content
        break
      end

      answer
    end


    def process_tool_calls(tcalls, messages, tool_results, content, exec, arts, stream = nil)
      if tcalls.any?
        new_messages, new_tool_results, divine_interrupt = handle_standard_tool_calls tcalls, messages, tool_results,
                                                                                      content, exec, stream
        if divine_interrupt
          # Return divine interruption signal to terminate current oracle call
          return divine_interrupt
        end

        messages.replace new_messages
        tool_results.replace new_tool_results
        return true
      end

      # In reasoning mode, skip tool call extraction entirely
      tools_from_content = Artificer.extract_instrumenta_from_content content
      if tools_from_content.any?
        new_messages, new_tool_results, divine_interrupt = handle_fallback_tool_calls tools_from_content, messages,
                                                                                      tool_results, content, exec, arts, stream
        if divine_interrupt
          # Return divine interruption signal to terminate current oracle call
          return divine_interrupt
        end

        messages.replace new_messages
        tool_results.replace new_tool_results
        return true
      end

      false
    end


    def conjuration(prompt, context, msg_uuid:, tools: nil, stream: nil, &block)
      set_temperature = set_temperature_from_context context
      result = divination(prompt, context, tools:, reasoning: true, msg_uuid:, stream:, &block)
      result
    rescue StandardError => e
      error_details = Conduit.extract_deepseek_error_details e
      error_message = error_details[:message] || e.message
      (stream || HorologiumAeternum).system_error "Conjuration failed: #{error_message.truncate 100}"
      { error: "Conjuration failed: #{error_message}", details: error_details }
    end


    public :conjuration


    def complete(context)
      Conduit.complete context
    end


    # Message Construction
    def base_messages(prompt_or_messages, context, reasoning, system_prompt)
      prompt, custom_messages = if prompt_or_messages.is_a? String
                                  [prompt_or_messages, nil]
                                else
                                  [nil, prompt_or_messages]
                                end
      hermetic_manifest = context.dig :extra_context, :hermetic_manifest
      hermetic_manifest = hermetic_manifest[:content] if hermetic_manifest.present?
      attachments = context.dig :extra_context, :attachments
      project_summary = context.dig :extra_context, :project_summary
      project_summary = if project_summary.present?
        working_dir = context.dig(:extra_context, :aegis_orientation, :working_dir)
        label = if working_dir.present?
          "PROJECT STRUCTURE (scope: #{working_dir}):"
        else
          "PROJECT STRUCTURE (top-level):"
        end
        "#{label}\n#{project_summary}"
      end
      aegis_orientation = context.dig :extra_context, :aegis_orientation
      aegis_orientation = if aegis_orientation.present?
        "AEGIS ORIENTATION: #{aegis_orientation.to_s_no_quotes}"
      end

      aegis_notes = context.dig :extra_context, :aegis_notes
      aegis_notes = if aegis_notes.present?
        aegis_notes.map!{ |note| note.to_s_no_quotes }
        "AEGIS NOTES: #{aegis_notes.join "\n------\n"}" 
      end      
      
      system_prompt = [
        (reasoning ? REASONING_PROMPT : SYSTEM_PROMPT),
        system_prompt,
        project_summary,
        aegis_notes,
        aegis_orientation,
        hermetic_manifest
      ].compact.join "\n\n=======\n\n"

      # puts "[ORACLE][DEBUG]: System prompt length: #{system_prompt.length}"
      # puts "[ORACLE][DEBUG]: System prompt preview: #{system_prompt[0..200]}..."
      include_briefing = reasoning && :deepseek == CONFIG::CFG[:api_type]

      messages = if custom_messages
                   # For task execution with complete message structure - use it directly
                   [
                     { role: 'system', content: system_prompt },
                     *custom_messages
                   ]
                 else
                   # Normal chat: include history and briefing
                   [
                     { role: 'system', content: system_prompt },
                     *context[:history],
                     ({ role: 'system', content: SYSTEM_PROMPT_BRIEFING } if include_briefing),
                     { role: 'user', content: if attachments && attachments.any?
                                                [
                                                  { type: :text, text: prompt },
                                                  { type: :text,
                                                    text: render_attachments(attachments) }
                                                ]
                                              else
                                                prompt
                                              end }
                   ]
                 end.compact

      messages.each_with_index do |msg, i|
             "byte_length=#{msg[:content].to_s.size}, " \
             "token_length=#{msg[:content].to_s.tok_len}, " \
             "message=#{msg.inspect.truncate 150000}"
      end

      messages
    end


    # Format messages specifically for Gemini API
    # Gemini requires different structure for attachments and system messages
    def format_messages_for_gemini(messages, attachments = nil)
      gemini_messages = []

      messages.each do |message|
        case message[:role]
        when 'system'
          # Gemini doesn't have system role, convert to user with instruction prefix
          gemini_messages << {
            role: 'user',
            parts: [{
              text: "[SYSTEM INSTRUCTION] #{message[:content]}"
            }]
          }
        when 'user'
          if message[:content].is_a?(Array) && attachments
            # Handle attachments - Gemini uses parts array with text and file data
            parts = message[:content].map do |content|
              if content[:type] == :text
                { text: content[:text] }
              else
                # Handle file attachments (future implementation)
                { text: "[ATTACHMENT: #{content[:text]}]" }
              end
            end
            gemini_messages << { role: 'user', parts: parts }
          else
            # Regular text message
            gemini_messages << {
              role: 'user',
              parts: [{ text: message[:content].to_s }]
            }
          end
        when 'assistant'
          gemini_messages << {
            role: 'model',
            parts: [{ text: message[:content].to_s }]
          }
        end
      end

      # Add attachments as separate parts if provided
      if attachments && !attachments.empty?
        # Find the last user message to append attachments
        last_user_msg = gemini_messages.reverse.find { |msg| msg[:role] == 'user' }
        if last_user_msg
          attachment_text = render_attachments(attachments)
          last_user_msg[:parts] << { text: attachment_text }
        else
          # No user message found, create new one for attachments
          gemini_messages << {
            role: 'user',
            parts: [{ text: render_attachments(attachments) }]
          }
        end
      end

      gemini_messages
    end


    def render_attachments(attachments)
      x = <<~ATTACHMENT_PROMPT
        # ATTACHMENTS
        #{attachments.inspect}
      ATTACHMENT_PROMPT

      x
    end


    # Core Divination Flow
    def stream_reasoning_content(arts)
      nil unless arts[:reasoning_content].present? && defined?(HorologiumAeternum)
    rescue StandardError => e
      error_msg = "Failed to stream reasoning content: #{e.message.truncate 100}"
      HorologiumAeternum.system_error error_msg
    end


    def stream_initial_status(msg_uuid, stream = nil, set_temperature = nil)
      sink = stream || HorologiumAeternum
      return unless sink

      aegis = Mnemosyne.aegis || {}
      temperature = set_temperature || (aegis[:temperature] || 1.0).to_f
      thinking = (aegis[:thinking] || 'normal').to_s
      sleep 0.1
      sink.thinking 'Consulting the hermetic oracle...', uuid: msg_uuid,
                     temperature: temperature, thinking: thinking
    end


    # def check_temperature_restart(initial_temperature)
    #   current_temperature = (Mnemosyne.aegis[:temperature] || 1.0).to_f
    #   return unless TEMPERATURE_DELTA_THRESHOLD < (current_temperature - initial_temperature).abs
    #
    #   HorologiumAeternum.thinking 'Temperature change detected.。.'
    #   # raise RestartException, 'Temperature change detected. Restarting oracle.'
    # end


    def add_assistant_message(_messages, content, tcalls, arts = {})
      assistant_msg = { role: 'assistant', content: }
      assistant_msg[:tool_calls] = tcalls if tcalls.present?
      assistant_msg[:reasoning_content] = arts[:reasoning_content] if arts[:reasoning_content].present?
      assistant_msg
    rescue StandardError => e
      HorologiumAeternum.system_error "Failed to add assistant message: #{e.message.truncate 100}"
      { role: 'assistant', content: '' }
    end


    def collect_prelude_content(arts, content)
      arts[:prelude] << content if content.present?
      arts
    rescue StandardError => e
      HorologiumAeternum.system_error "Failed to collect prelude content: #{e.message.truncate 100}"
      arts
    end


    def set_temperature_from_context(context = nil)
      # Use temperature from context if provided, otherwise use Aegis temperature
      context_temperature = context&.dig :extra_context, :temperature
      context_temperature&.to_f
      # context_temperature || (Mnemosyne.aegis[:temperature] || 1.0).to_f
    end


    # Tool Call Handling
    def handle_standard_tool_calls(tools_from_content, messages, tool_results, content, exec, stream = nil)
      sink = stream || HorologiumAeternum
      if content.present?
        sink.oracle_revelation content
      end

      results, new_messages, new_tool_results = Artificer.execute_instrumenta_calls(
        tools_from_content, messages, tool_results, content, sink:, &exec
      )

      # Check for divine interruption in results - return signal directly
      divine_interrupt = divine_interruption_signal_from_tool_result results
      return [new_messages, new_tool_results, divine_interrupt] if divine_interrupt

      [new_messages, new_tool_results, nil]
    end


    private
    

    # Generate a unique session ID based on context
    def generate_session_id(context)
      # Use task_id if available, otherwise create hash of context
      task_id = context.dig :extra_context, :task_context, :task_id
      return "task_#{task_id}" if task_id

      # Fallback: hash of relevant context elements
      context_hash = Digest::MD5.hexdigest [
        context.dig(:extra_context, :file),
        context.dig(:extra_context, :selection),
        Time.now.to_i / 60 # Round to nearest minute
      ].compact.join('|')
      "session_#{context_hash}"
    end


    def handle_fallback_tool_calls(tools_from_content, messages, tool_results, content, exec, arts, stream = nil)
      sink = stream || HorologiumAeternum
      if content.present?
        sink.oracle_revelation content
      end

      arts[:tools] = tools_from_content
      if arts[:plan].present?
        sink.thinking "Plan: #{arts[:plan].join ' → '}"
      end

      results, new_messages, new_tool_results = Artificer.execute_fallback_instrumenta_calls(
        tools_from_content, messages, tool_results, sink:, &exec
      )

      # Check for divine interruption in results - return signal directly
      divine_interrupt = divine_interruption_signal_from_tool_result results

      # puts "DIVINE_INTERRUPTION_SIGNAL_FROM_TOOL_RESULT=#{divine_interrupt.inspect}"
      return [new_messages, new_tool_results, divine_interrupt] if divine_interrupt

      [new_messages, new_tool_results, nil]
    rescue StandardError => e
      error_msg = "Failed to handle fallback tool calls: #{e.message.truncate 100}"
      sink.system_error error_msg
      [messages, tool_results]
    end


    def handle_step_termination_exception(exception, answer, arts, tool_results, stream = nil)
      sink = stream || HorologiumAeternum
      sink.system_error "Step termination: #{exception.message.truncate 100}"
      [answer || '<<step terminated>>', arts, tool_results]
    end


    # Extract divine interruption signal from tool execution results
    def divine_interruption_signal_from_tool_result(results)
      # puts "divine_interruption_signal_from_tool_result #{results.inspect}"
      return nil unless results.is_a? Array

      results.find do |result|
        result.is_a?(Hash) &&
          result.key?(:__divine_interrupt)
      end
    end


    public :divine_interruption_signal_from_tool_result


    def handle_divination_error(exception, tool_results = [])
      log_json(error: exception.message || exception, backtrace: exception.backtrace,
               info: exception.inspect)

      error_details = Conduit.extract_deepseek_error_details exception

      [{ error: error_details[:message] || exception.message, details: error_details },
       { patch: nil, tasks: nil, tools: [], prelude: [] }, tool_results]
    rescue StandardError => e
      [{ error: "Critical error in error handling: #{e.message}" },
       { patch: nil, tasks: nil, tools: [], prelude: [] }, tool_results]
    end


    # Configuration and Utilities
    def load_cfg
      Conduit.load_cfg
    end
  end
end