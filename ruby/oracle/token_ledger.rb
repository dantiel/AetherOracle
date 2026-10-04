# frozen_string_literal: true

require 'fileutils'

# TokenLedger — hermetic accounting of the oracle's breath.
#
# Prices each completed turn (prompt + completion tokens) against a per-model
# USD table (dollars per million tokens) and persists the cumulative totals into
# the project `.aethercodex` under a `token-usage:` section, so every session
# can report both what it just spent and the all-time ledger.
#
# List prices are published provider rates and drift; override them in
# `.aethercodex` under `token-pricing:` — either globally or per model:
#
#   token-pricing:
#     input-per-million: 1.25
#     output-per-million: 10.0
#     gemini-2.5-pro:
#       input-per-million: 1.25
#       output-per-million: 10.0
module TokenLedger
  # USD per million tokens (cache-miss input). Published list rates.
  PRICING = {
    # DeepSeek
    'deepseek-chat'     => { input: 0.27, output: 1.10 },
    'deepseek-reasoner' => { input: 0.55, output: 2.19 },
    # OpenAI
    'gpt-4o'            => { input: 2.50, output: 10.00 },
    'gpt-4o-mini'       => { input: 0.15, output: 0.60 },
    'gpt-4.1'           => { input: 2.00, output: 8.00 },
    'gpt-4.1-mini'      => { input: 0.40, output: 1.60 },
    'gpt-5'             => { input: 1.25, output: 10.00 },
    'gpt-5-mini'        => { input: 0.25, output: 2.00 },
    # Anthropic
    'claude-sonnet-4-5' => { input: 3.00, output: 15.00 },
    'claude-opus-4-5'   => { input: 5.00, output: 25.00 },
    'claude-haiku-4-5'  => { input: 1.00, output: 5.00 },
    # Gemini
    'gemini-2.5-pro'    => { input: 1.25, output: 10.00 },
    'gemini-2.5-flash'  => { input: 0.30, output: 2.50 }
  }.freeze

  MILLION = 1_000_000.0

  class << self
    # --- pricing -----------------------------------------------------------

    def pricing_for(model)
      name = normalize_model(model)
      spec = PRICING[name] || {}
      override = config_pricing_for(name)
      input  = price_from(override, :input)  || spec[:input]  || global_price(:input)
      output = price_from(override, :output) || spec[:output] || global_price(:output)

      # Unknown/custom models fall back to their provider's list rate so the
      # ledger never silently prices a turn at $0.
      if input.nil? || output.nil?
        fallback = provider_pricing
        input  ||= fallback[:input]
        output ||= fallback[:output]
      end

      { input: (input || 0.0).to_f, output: (output || 0.0).to_f }
    end

    def cost_for(model, prompt_tokens, completion_tokens)
      p = pricing_for(model)
      (prompt_tokens.to_f / MILLION) * p[:input] +
        (completion_tokens.to_f / MILLION) * p[:output]
    end

    # --- session + persisted state -----------------------------------------

    # Begin a fresh accounting window (called when the chamber opens).
    def reset_session!
      @session = zeros
      @session_active = false
      @persisted = nil
    end

    def session
      @session ||= zeros
    end

    def persisted
      @persisted ||= load_persisted
    end

    # Record one completed turn: accumulate into the session window, fold into
    # the all-time ledger and persist the latter to `.aethercodex`. Best-effort —
    # accounting must never break the divination.
    def record!(model, prompt_tokens, completion_tokens)
      prompt = prompt_tokens.to_i
      completion = completion_tokens.to_i
      cost = cost_for(model, prompt, completion)

      begin_session! unless @session_active

      s = session
      s[:prompt_tokens] += prompt
      s[:completion_tokens] += completion
      s[:cost] += cost
      s[:turns] += 1

      p = persisted
      p[:prompt_tokens] += prompt
      p[:completion_tokens] += completion
      p[:cost] += cost
      write_section(p)

      { prompt_tokens: prompt, completion_tokens: completion, cost: cost }
    rescue StandardError
      { prompt_tokens: prompt_tokens.to_i, completion_tokens: completion_tokens.to_i, cost: 0.0 }
    end

    def end_session!
      @session_active = false
      session
    end

    # --- rendering ---------------------------------------------------------

    def format_usd(value)
      v = value.to_f
      return '$0.00' if v <= 0
      v >= 0.01 ? format('$%.4f', v) : format('$%.6f', v)
    end

    # One line shown when the chamber opens: the all-time ledger.
    def opening_line
      p = persisted
      "  :: Ledger: #{format_usd(p[:cost])} all-time — " \
        "#{p[:prompt_tokens] + p[:completion_tokens]} tokens in #{p[:sessions]} sessions"
    end

    # One line shown when the chamber closes: this session vs. all-time.
    def closing_line
      s = session
      p = persisted
      "  :: Session: #{format_usd(s[:cost])} " \
        "(#{s[:prompt_tokens] + s[:completion_tokens]} tokens, #{s[:turns]} turns) — " \
        "all-time #{format_usd(p[:cost])}"
    end

    private

    def zeros
      { prompt_tokens: 0, completion_tokens: 0, cost: 0.0, turns: 0 }
    end

    def begin_session!
      @session = zeros
      @persisted = load_persisted
      @persisted[:sessions] += 1
      @session_active = true
    end

    def normalize_model(model)
      name = model.to_s.strip
      name.empty? ? nil : name.split('/').last
    end

    def config_pricing
      raw = CONFIG::CFG[:token_pricing] || CONFIG::CFG['token-pricing'] || {}
      raw.is_a?(Hash) ? raw : {}
    end

    def config_pricing_for(model_name)
      raw = config_pricing
      [model_name, hermetic_key(model_name)].each do |k|
        v = raw[k] || raw[k.to_s] || raw[k.to_sym]
        return v if v.is_a?(Hash)
      end
      {}
    end

    def hermetic_key(name)
      name.to_s.gsub(/[^a-zA-Z0-9_]/, '_').gsub(/_+/, '_').downcase.to_sym
    end

    def price_from(hash, kind)
      return nil unless hash.is_a?(Hash)
      [
        hash[kind], hash[kind.to_s],
        hash["#{kind}-per-million"], hash[:"#{kind}_per_million"], hash["#{kind}_per_million"]
      ].compact.map(&:to_f).first
    end

    def provider_pricing
      case CONFIG.api_type.to_s.downcase
      when 'deepseek' then PRICING['deepseek-chat']
      when 'openai'   then PRICING['gpt-4o']
      when 'anthropic' then PRICING['claude-sonnet-4-5']
      when 'gemini'   then PRICING['gemini-2.5-pro']
      else PRICING['deepseek-chat']
      end
    end

    def global_price(kind)
      raw = config_pricing
      [
        raw["#{kind}-per-million"], raw[:"#{kind}_per_million"], raw["#{kind}_per_million"]
      ].compact.map(&:to_f).first
    end

    def load_persisted
      raw = CONFIG::CFG[:token_usage] || CONFIG::CFG['token-usage'] || {}
      raw = {} unless raw.is_a?(Hash)
      {
        prompt_tokens: (raw[:prompt_tokens] || raw['prompt-tokens'] || 0).to_i,
        completion_tokens: (raw[:completion_tokens] || raw['completion-tokens'] || 0).to_i,
        cost: (raw[:cost_usd] || raw['cost-usd'] || 0).to_f,
        sessions: (raw[:sessions] || raw['sessions'] || 0).to_i
      }
    end

    def write_section(p)
      path = CONFIG.project_config_path
      lines = File.exist?(path) ? File.readlines(path) : []
      body = section_yaml(p)
      idx = lines.index { |l| l =~ /^token-usage:\s*$/ }

      if idx
        finish = idx + 1
        finish += 1 while finish < lines.size && (lines[finish] =~ /^\s/ || lines[finish].strip.empty?)
        lines[idx...finish] = ["token-usage:\n"] + body.lines
      else
        lines << "\n" if lines.any? && !lines.last.end_with?("\n")
        unless lines.join.include?('TOKEN USAGE')
          lines << "# === TOKEN USAGE (hermetic accounting) =================================\n"
        end
        lines << "token-usage:\n"
        lines.concat body.lines
      end

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, lines.join)
    end

    def section_yaml(p)
      [
        "  prompt-tokens: #{p[:prompt_tokens].to_i}\n",
        "  completion-tokens: #{p[:completion_tokens].to_i}\n",
        "  cost-usd: #{format('%.6f', p[:cost].to_f)}\n",
        "  sessions: #{p[:sessions].to_i}\n"
      ].join
    end
  end
end