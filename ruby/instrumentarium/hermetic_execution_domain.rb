# frozen_string_literal: true

require 'net/protocol'
require 'faraday'
require_relative 'metaprogramming_utils'
# Don't require Oracle to avoid circular dependency - use string constant instead

# HermeticExecutionDomain provides isolated execution context for tool operations
# with structured error handling, automatic retry mechanisms, and execution isolation
class HermeticExecutionDomain
  # Base error class for hermetic execution domain
  class Error < StandardError; end

  # Error indicating tool execution failure
  class ToolExecutionError < Error; end

  # Error indicating timeout during execution
  class TimeoutError < Error; end

  # Error indicating rate limiting
  class RateLimitError < Error; end

  # Error indicating network issues
  class NetworkError < Error; end

  # Error indicating context length exceeded
  class ContextLengthError < Error; end

  # Error indicating context length exceeded
  class ParseErrorError < Error; end

  class << self
    # Execute a block within the hermetic execution domain
    # Provides structured error handling, automatic classification, and execution isolation
    def execute(max_retries: 1, timeout: nil, &block)
      retries = 0

      begin
        result = if timeout && Float::INFINITY != timeout && 1_000_000 > timeout
                   with_timeout(timeout, &block)
                 else
                   block.call
                 end
        log_execution_success result
        result
      rescue Timeout::Error, Net::ReadTimeout => e
        retries = handle_retry :timeout, e, retries, max_retries
        retry
      rescue RateLimitError, Faraday::TooManyRequestsError => e
        retries = handle_retry :rate_limit, e, retries, max_retries
        retry
      rescue Faraday::ConnectionFailed, Net::OpenTimeout, SocketError => e
        retries = handle_retry :network, e, retries, max_retries
        retry
      rescue JSON::ParserError, ArgumentError => e
        retries = handle_retry :parse_error, e, retries, max_retries
        retry
      rescue => e
        # Handle Oracle::StepTerminationException if defined, otherwise handle as generic error
        if e.class.name == 'Oracle::StepTerminationException'
          # Step termination is expected - re-raise to allow proper handling at Oracle level
          raise e
        else
          retries = handle_retry :tool_execution, e, retries, max_retries
          retry
        end
      rescue StandardError => e
        classified_error = classify_error e
        raise classified_error, "Tool execution failed: #{e.message.truncate 300}"
      end
    end

    private

    # Hard lease: run the instrument in a leased thread and reap it if it
    # overstays. `Timeout.timeout` alone cannot interrupt native blocking calls
    # (file I/O on a stalled mount, a hung subprocess, a deep native parse) —
    # a silent file_overview must not starve the single serial worker FIFO.
    def with_timeout(timeout, &block)
      return block.call if timeout.nil? || timeout <= 0 || timeout >= 1_000_000

      carry = {}
      %i[aether_sink aether_request_id aether_tool_uuid paused].each do |key|
        carry[key] = Thread.current[key] if Thread.current.key?(key)
      end

      worker = Thread.new do
        carry.each { |key, value| Thread.current[key] = value }
        block.call
      end

      return worker.value if worker.join(timeout)

      worker.kill
      begin
        worker.join(1)
      rescue StandardError
        nil
      end
      raise Timeout::Error, "instrument lease expired after #{timeout}s"
    end


    def handle_retry(error_type, error, retries, max_retries)
      if retries < max_retries
        retries += 1
        sleep 2**retries # Exponential backoff
        log_retry_attempt error_type, retries, max_retries
        retries
      else
        raise HermeticExecutionDomain.const_get("#{error_type.to_s.camelize}Error"),
              "#{error_type.to_s.humanize}: #{error.message.truncate 300}"
      end
    end


    def classify_error(error)
      error_message = error.message.to_s.downcase

      if error_message.include?('context length') || error_message.include?('maximum context')
        ContextLengthError
      elsif error_message.include?('timeout') || error.is_a?(Timeout::Error)
        TimeoutError
      elsif error_message.include?('rate limit') || error_message.include?('rate_limit')
        RateLimitError
      elsif error_message.include?('network') || error_message.include?('connection')
        NetworkError
      else
        ToolExecutionError
      end
    end


    def log_execution_success(_result)
      puts '[HERMETIC_DOMAIN][SUCCESS]: Execution completed successfully'
    end


    def log_retry_attempt(error_type, retry_count, max_retries)
      puts "[HERMETIC_DOMAIN][RETRY]: #{error_type} error, attempt #{retry_count}/#{max_retries}"
    end
  end
end