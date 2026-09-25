# frozen_string_literal: true

require 'securerandom'
require_relative '../instrumentarium/scriptorium'
require_relative '../instrumentarium/metaprogramming_utils'
require_relative '../instrumentarium/hermetic_execution_domain'
require_relative '../instrumentarium/companion_programs'
require_relative 'coniunctio'
require_relative 'oracle'

using MetaprogrammingUtils



# Aetherflux channel for oracle communication with functional purity
class Aetherflux
  class << self
    def channel_oracle_divination(params, tools:, context: nil, timeout: nil, resume_state: nil)
      # Active companions veil their facets into Aegis BEFORE the context build, so the
      # orientation carries their personas and the facet notes flow into memory.
      # Many companions may be active at once; the agent then sees each of their tools.
      active = Array(params[:active_companions]).compact.map(&:to_sym)
      active = [params[:companion].to_sym].compact if active.empty? && params[:companion]
      previous_aegis = CompanionPrograms.veil(active, params[:system_prompt]) if active.any?
      prev_silent = Thread.current[:aether_silent]
      start_time = Time.now
      msg_uuid = HorologiumAeternum.divination "Initializing astral connection..."

      # Pass the context parameters to Coniunctio for proper handling
      ctx = Coniunctio.build(context:, **params)

      begin
        # Ephemeral turns (flash conjuration) breathe silently: no status frames
        # leak into Pythia's shared stream. Set inside the begin so the `ensure`
        # always restores it even if the context build above raised. Thread-local
        # to the single worker.
        Thread.current[:aether_silent] = true if params[:ephemeral]
        # Use standard divination method for both normal and task execution
        # The context flag will be handled by Coniunctio to exclude chat history
        # The system prompt will be handled by Oracle.base_messages for proper message construction
        # For task execution, pass empty prompt since messages contain the complete structure
        divination_prompt = params[:messages] || params[:prompt]
        system_prompt = if params[:companion]
                          CompanionPrograms.build_system_prompt(params[:companion], params[:system_prompt])
                        else
                          params[:system_prompt]
                        end
        # Scope the agent's tools. Companion tools are namespaced and only present for
        # active companions. A consult turn gives the companion its own specialist set;
        # otherwise the main agent keeps the core instruments plus every active
        # companion's consult/suggest/say/commit tools.
        #
        # The task engine passes its own filtered toolset (task_complete_step, etc.) via
        # the `tools:` keyword. Respect that specific toolset — otherwise the task tools
        # would be discarded and the model would never receive its step-completion tools.
        tools = if params[:companion]
                  Instrumenta.select(*CompanionPrograms.tools_for(
                    params[:companion], all_tools: Instrumenta.tools,
                    suggestion_execution: params[:suggestion_execution]
                  ))
                elsif tools.nil? || tools.equal?(Instrumenta)
                  core = Instrumenta.tools.keys - CompanionPrograms.companion_tool_names
                  Instrumenta.select(*(core + CompanionPrograms.toolset(active)))
                else
                  tools
                end
        # A consult turn speaks with the companion's own temperament: personality-driven
        # temperature + thinking. Optional overrides arrive from a suggestion payload;
        # otherwise the companion's hermetic defaults rule. The veil/release cycle in
        # `ensure` restores the previous thinking level.
        if params[:companion]
          glyph = params[:companion].to_sym
          temp  = CompanionPrograms.temperature(glyph, params[:temperature])
          think = CompanionPrograms.thinking(glyph, params[:thinking])
          ctx[:extra_context][:temperature] = temp.to_f if temp
          Mnemosyne.unveil_aegis(thinking: think) if think
        end
        result = Oracle.divination divination_prompt, ctx, tools:, msg_uuid:,
                                   system_prompt: system_prompt,
                                   resume_state: resume_state do |name, args, tool_ctx|
          # Confirmation gate: executor-tier companions must confirm destructive verbs.
          if CompanionPrograms.requires_confirmation?(params[:companion], name)
            approved = confirm_destructive(params[:companion], name)
            next approved unless approved == :approved
          end
          tool_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = tools.handle tool: name, args:, context: tool_ctx, timeout: timeout
          exec_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - tool_start
          result.is_a?(Hash) ? result.merge(execution_time: exec_time.round(3)) : result
        end

        puts "CHECK FOR DIVINE INTERRUPT #{result.inspect.truncate 200}"
        # Check if we got a divine interruption signal instead of regular answer
        if result.first&.is_a?(Hash) && result.first&.key?(:__divine_interrupt)
          puts 'DIVINE INTERRUPT FOUND - returning directly'
          # Return the divine interruption signal directly
          return result
        end

        # Normal response - destructure the array
        answer, arts, tool_results = result
      rescue Oracle::RestartException => e
        puts "[ORACLE][RestartException]: #{e.inspect}"
        HorologiumAeternum.thinking 'Restarting oracle process due to temperature change...'
        Mnemosyne.record params, '<<temperature change handled>>' if params[:record]
        retry
      end

      puts 'CHECK FOR STANDARD ERROR'
      raise StandardError, answer unless answer.is_a? String

      # Extract AI-driven companion suggestions (<companion-suggestions>) before rendering
      answer, companion_suggestions = extract_companion_suggestions(answer)
      # Merge suggestions emitted via the `suggest` instrument with the text-block ones.
      companion_suggestions = (companion_suggestions + collect_tool_suggestions(tool_results)).uniq { |s| [s[:glyph], s[:prompt]] }
      # Collect `say`/`_ask` info messages into the chat-flow logs.
      logs = collect_say_logs(tool_results)

      html = Scriptorium.html_with_syntax_highlight answer.to_s
      #HorologiumAeternum.oracle_revelation answer.to_s unless answer.to_s.strip.empty?

      # Calculate execution time and tool call metrics
      execution_time = Time.now - start_time
      tool_call_count = tool_results&.length || 0

      # Thinking time is already sent as 'thinking_complete' status event from oracle.rb
      # Keep only total execution_time and tool_execution_times for the answer response

      HorologiumAeternum.completed Scriptorium.html("🎯 Response ready with **#{tool_call_count}** tools executed in #{execution_time.round 2}s")

      # Record with execution metrics if requested
      if params[:record]
        Mnemosyne.record(prompt: params[:prompt], execution_time:,
                         tool_call_count:, answer:, tool_calls: tool_results)
      end

      # Extract per-tool execution times from tool_results
      tool_execution_times = (tool_results || []).map do |tr|
        { name: tr[:name], execution_time: tr[:execution_time] || 0 }
      end

      {
        status:   :success,
        response: {
          reasoning:            arts[:reasoning],
          reasoning_content:    arts[:reasoning_content],
          answer:               answer,
          html:                 html,
          companion_suggestions: companion_suggestions,
          patch:                arts[:patch],
          tasks:                arts[:tasks],
          tools:                arts[:tools],
          tool_results:         tool_results,
          logs:                 logs,
          next_step:            arts[:next_step],
          execution_time:       execution_time,
          tool_call_count:      tool_call_count,
          tool_execution_times: tool_execution_times
        }
      }
    rescue TypeError => e
      { status: :failure, response: "Type error: #{e.full_message || e.message}" }
    rescue HermeticExecutionDomain::TimeoutError => e
      { status: :timeout, response: "Timeout: #{e.message.truncate 100}" }
    rescue HermeticExecutionDomain::RateLimitError => e
      { status: :rate_limit_error, response: "Rate limit: #{e.message.truncate 100}" }
    rescue HermeticExecutionDomain::NetworkError => e
      { status: :network_error, response: "Network error: #{e.message.truncate 100}" }
    rescue HermeticExecutionDomain::ContextLengthError => e
      { status:   :context_length_error,
        response: "Context length exceeded: #{e.message.truncate 100}" }
    rescue HermeticExecutionDomain::ToolExecutionError => e
      { status: :failure, response: "Tool execution error: #{e.message.truncate 100}" }
    rescue StandardError => e
      error_message = e.message.to_s
      # Mnemosyne.record params, "Error: #{error_message}" if params[:record]
      if params[:record]
        Mnemosyne.record(prompt: params[:prompt], 
                         answer: "Error: #{error_message}, Answer: #{answer}", 
                         execution_time:, tool_call_count:)
      end

      status = classify_error error_message, e
      { status:    status,
        response:  "#{status.to_s.humanize}: #{error_message}",
        backtrace: e.backtrace }
    ensure
      Thread.current[:aether_silent] = prev_silent
      CompanionPrograms.release(previous_aegis) if previous_aegis
    end


    # Extract <companion-suggestions> blocks emitted by the oracle.
    # Returns [cleaned_text, suggestions] where each suggestion is
    # { glyph:, name:, prompt: } — mapped to companion ids on the frontend.
    def extract_companion_suggestions(text)
      return [text, []] unless text.is_a?(String)

      match = text.match(/<companion-suggestions>([\s\S]*?)<\/companion-suggestions>/i)
      return [text, []] unless match

      cleaned = text.gsub(match[0], '')
      suggestions = []
      # Greedy capture to the final quote on the line: prompts may legitimately
      # contain inner quotes (e.g. »Soll ich "X" prüfen?«). `.+` is line-scoped
      # (`.` never matches \n), so it never bleeds into the next suggestion.
      match[1].scan(/(\p{Emoji}(?:\p{Emoji}|\u200D|\uFE0F|\uFE0E)*)\s+(.+?):\s*"(.+)"/) do |glyph, name, prompt|
        suggestions << { glyph: glyph.strip, name: name.strip, prompt: prompt.strip }
      end
      [cleaned, suggestions]
    end


    def channel_oracle_conjuration(params, tools:, context: nil, timeout: nil)
      start_time = Time.now
      msg_uuid = HorologiumAeternum.divination 'Initializing astral connection...'
      ctx = Coniunctio.build(context ? params.merge(context: context) : params)

      begin
        # For reasoning, we must use empty tools array to enable DeepSeek advanced reasoning
        # The reasoning model cannot execute tools, so we provide empty array
        # This is handled automatically in Conduit based on model detection
        answer, arts, tool_results = Oracle.conjuration(params[:prompt], ctx, tools: tools,
                                                         msg_uuid:) do |name, args, tool_ctx|
          # Tool execution is handled normally, but tools will be filtered in Conduit
          # for reasoning models to enable advanced reasoning capabilities
          if tools.respond_to? :handle
            tools.handle tool: name, args:, context: tool_ctx, timeout: timeout
          else
            { error: 'No tools available for execution' }
          end
        end

        # Calculate execution time and tool call metrics
        execution_time = Time.now - start_time
        tool_call_count = tool_results&.length || 0
      rescue Oracle::RestartException
        HorologiumAeternum.thinking 'Restarting oracle process due to temperature change...'
        retry
      end

      html = Scriptorium.html_with_syntax_highlight answer.to_s
      # HorologiumAeternum.oracle_revelation answer.to_s unless answer.to_s.strip.empty?

      # HorologiumAeternum.completed "🎯 Response ready with **#{tool_call_count}** tools executed in #{execution_time.round(2)}s"

      {
        status:   :success,
        response: {
          reasoning:       arts[:reasoning],
          answer:          answer,
          html:            html,
          patch:           arts[:patch],
          tasks:           arts[:tasks],
          tools:           arts[:tools],
          tool_results:    tool_results,
          logs:            [],
          next_step:       arts[:next_step],
          execution_time:  execution_time,
          tool_call_count: tool_call_count
        }
      }
    rescue StandardError => e
      execution_time = Time.now - start_time
      HorologiumAeternum.server_error "Oracle reasoning stream failed: #{e.message}"
      { status: :failure, response: "Oracle reasoning stream failed: #{e.message}" }
    ensure
      if params[:record]
        execution_time ||= Time.now - start_time
        tool_call_count ||= 0
        Mnemosyne.record(**params, answer: "Error: #{error_message}", execution_time:,
                                   tool_call_count:, answer:)
      end
    end

    private

    # Collect suggestions emitted via a companion's `_suggest` instrument.
    def collect_tool_suggestions(tool_results)
      (tool_results || []).filter_map do |tr|
        next unless tr[:name].to_s.end_with?('_suggest')

        r = tr[:result]
        r[:suggestion] if r.is_a?(Hash) && r[:suggestion].is_a?(Hash)
      end
    end

    # Collect info messages emitted via `_say` (and `_ask` consultation results)
    # into chat-flow logs. The companion is derived from the namespaced tool name.
    def collect_say_logs(tool_results)
      (tool_results || []).filter_map do |tr|
        name = tr[:name].to_s
        next unless name.end_with?('_say') || name.end_with?('_ask')

        r = tr[:result]
        next unless r.is_a?(Hash) && r[:say].is_a?(Hash)

        companion = name.sub(/_(say|ask)$/, '')
        say = r[:say].dup
        # Keep the plain markdown for the Swift chat flow; carry the highlighted
        # HTML alongside for any future rich renderer.
        say[:html] = Scriptorium.html_with_syntax_highlight(say[:message].to_s)
        glyph = begin
          COMPANION_PERSONALITIES[companion.to_sym]&.dig(:glyph)
        rescue StandardError
          nil
        end
        { type: 'say', data: say, companion: companion, glyph: glyph || '✦' }
      end
    end

    # Ask the user to confirm a destructive tool call (executor-tier companion).
    # Returns :approved to proceed, or a result hash the model relays on abort.
    def confirm_destructive(glyph, name)
      ask_uuid = SecureRandom.uuid
      HorologiumAeternum.send_status('ask_user', {
                                       type: 'confirm',
                                       message: "#{CompanionPrograms.display_name(glyph)} möchte die destruktive " \
                                                "Operation `#{name}` ausführen — irreversibel. Fortfahren?",
                                       options: %w[Confirm Abort]
                                     }, uuid: ask_uuid)
      response = HorologiumAeternum.await_user_response(ask_uuid)

      return :approved if response[:response]&.casecmp('confirm')&.zero?

      { aborted: true,
        note: "⛔ Vom Nutzer abgebrochen — `#{name}` wurde NICHT ausgeführt. " \
              'Informiere den Nutzer und biete keine Wiederholung an.' }
    end

    def classify_error(error_message, error)
      if error.is_a? Timeout::Error
        :timeout
      elsif error_message.include?('maximum context length') ||
            error_message.include?('context length') ||
            (error_message.include?('invalid_request_error') &&
             error_message.include?('context'))

        :context_length_error

      elsif error_message.include?('rate limit') ||
            error_message.include?('rate_limit') ||
            error_message.include?('rate_limit_exceeded')

        :rate_limit_error

      elsif error_message.include?('network') ||
            error_message.include?('connection') ||
            error.is_a?(Net::OpenTimeout) ||
            error.is_a?(Net::ReadTimeout) ||
            error_message.include?('read timeout') ||
            error_message.include?('Read timed out')

        :network_error

      else
        :failure
      end
    end
  end
end