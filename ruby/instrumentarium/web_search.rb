# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# ── DeepSeek Web Search & Fetch ─────────────────────────────────────────────
# Live web grounding for the oracle. DeepSeek exposes two read-only JSON APIs
# under the same bearer auth as the chat completions endpoint:
#
#   Search  POST /v1/tools/search   find pages for a query → structured results
#   Fetch   POST /v1/tools/fetch    retrieve one page → Markdown
#
# Both are billed per successful request (not by tokens), and both carry an
# account-level QPS limit of 5. Retry only transient statuses (408/429/5xx).
# See https://api-docs.deepseek.com/guides/search for the full schema.
module WebSearch
  SEARCH_PATH  = '/v1/tools/search'
  FETCH_PATH   = '/v1/tools/fetch'
  DEFAULT_BASE = 'https://api.deepseek.com'

  RETRY_STATUSES = [408, 429, 500, 502, 503, 504].freeze
  MAX_RETRIES    = 2

  module_function

  # Derive the DeepSeek origin from the chat endpoint (api_url), honouring an
  # explicit override. `https://api.deepseek.com/v1/chat/completions` reduces to
  # the base `https://api.deepseek.com`.
  def base_url
    override = ENV['DEEPSEEK_BASE_URL'].to_s.strip
    return override unless override.empty?

    uri  = URI.parse(CONFIG.api_url.to_s)
    port = uri.port
    port_part = port.to_i.zero? || port == uri.default_port ? '' : ":#{port}"
    "#{uri.scheme}://#{uri.host}#{port_part}"
  rescue StandardError
    DEFAULT_BASE
  end

  def api_key
    CONFIG.api_key.to_s.strip
  end

  def deepseek?
    CONFIG.api_type.to_s.downcase == 'deepseek' || base_url.downcase.include?('deepseek')
  end

  # The single gate the instrumentarium consults before registering the web
  # instruments. DeepSeek exposes them natively; any other provider must opt in
  # explicitly via `web-search.enabled: true` in `.aethercodex`.
  def available?
    return true if deepseek?

    enabled = CONFIG.web_search[:enabled]
    enabled == true || enabled.to_s.downcase == 'true'
  end

  # POST JSON to `path` and return `{ status:, body:, error: }`. Retries only
  # the transient statuses the API documents as safe to retry (408, 429, 5xx);
  # other 4xx are returned unchanged so the precise reason can be surfaced.
  def post_json(path, payload, timeout: 40)
    uri     = URI.parse("#{base_url}#{path}")
    retries = 0

    loop do
      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = 'https' == uri.scheme
        http.open_timeout = timeout / 2
        http.read_timeout = timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        request['Authorization'] = "Bearer #{api_key}"
        request['Content-Type']  = 'application/json'
        request.body = payload.to_json

        response = http.request(request)
        status   = response.code.to_i

        if RETRY_STATUSES.include?(status) && retries < MAX_RETRIES
          retries += 1
          sleep(2**retries)
          next
        end

        return { status: status, body: parse_body(response.body) }
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError,
             OpenSSL::SSL::SSLError => e
        return { status: 0, body: nil, error: e.message }
      end
    end
  end

  def parse_body(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    raw.to_s
  end

  # Extract a human-readable reason from an OpenAI-style error envelope.
  def error_message(result)
    return result[:error] if result[:error] && !result[:error].to_s.empty?

    body = result[:body]
    return "HTTP #{result[:status]}" unless body.is_a?(Hash)

    err = body['error'] || body[:error]
    return body.to_s unless err.is_a?(Hash)

    (err['message'] || err[:message] || err.to_s).to_s
  end

  # ── Public operations (used by the instruments below) ─────────────────────

  def search(query, count, ori_question, localization, need_content)
    payload = { query: query, count: count, need_content: need_content }
    payload[:ori_question] = ori_question unless ori_question.to_s.strip.empty?
    payload[:localization] = localization unless localization.to_s.strip.empty?

    result = post_json(SEARCH_PATH, payload, timeout: 40)

    if 200 == result[:status]
      results = result[:body].is_a?(Hash) ? result[:body]['results'] : nil
      { query: query, results: results || [] }
    else
      { error: "Web search failed (HTTP #{result[:status]}): #{error_message(result)}" }
    end
  rescue StandardError => e
    { error: "Web search failed: #{e.message}" }
  end

  def fetch(url)
    result = post_json(FETCH_PATH, { url: url }, timeout: 60)

    if 200 == result[:status]
      body = result[:body].is_a?(Hash) ? result[:body] : {}
      { title: body['title'].to_s, content: body['content'].to_s }
    else
      { error: "Web fetch failed (HTTP #{result[:status]}): #{error_message(result)}" }
    end
  rescue StandardError => e
    { error: "Web fetch failed: #{e.message}" }
  end
end

# ── web_search ───────────────────────────────────────────────────────────────
# Registered only when the configured provider exposes live web grounding
# (DeepSeek natively; any other provider via `web-search.enabled: true`).
if WebSearch.available?
  instrument :web_search,
             description: <<~DESC,
               Search the live web with DeepSeek's search engine and return structured
               results (title, url, snippet, summary, site_name, date, authority and,
               when requested, full content). Use this for current events, recent
               releases, or anything outside the model's training knowledge.

               The query supports operators: `site:`, `-site:`, `"exact phrase"`,
               `-"exact phrase"`, `-term`, `lang:`, `after:`, `before:`.
             DESC
             params: {
               query:        { type: String, required: true, minLength: 1, maxLength: 128,
                                description: 'Search query (1-128 chars; supports operators).' },
               count:        { type: Integer, default: 10, minimum: 1, maximum: 50,
                                description: 'Number of results to return (1-50).' },
               ori_question: { type: String, required: false, maxLength: 128,
                                description: "The user's original question that triggered the search, to improve query understanding." },
               localization: { type: String, required: false,
                                description: 'Optional IP address used to localize results.' },
               need_content: { type: 'boolean', default: false,
                                description: 'Return full page content in each result.' }
             },
             timeout: 60,
             returns: { query: String, results: Array, error: String } do |query:, count: 10, ori_question: nil, localization: nil, need_content: false|
    WebSearch.search(query, count, ori_question, localization, need_content)
  end

  # ── web_fetch ──────────────────────────────────────────────────────────────
  instrument :web_fetch,
             description: <<~DESC,
               Fetch a single web page and return its content as Markdown, via
               DeepSeek's Fetch API. Use this to read the full text of a page you
               already know the URL of (for example, a result returned by
               `web_search`).
             DESC
             params: {
               url: { type: String, required: true, minLength: 1, maxLength: 8192,
                       description: 'HTTP/HTTPS URL of the page to fetch.' }
             },
             timeout: 90,
             returns: { title: String, content: String, error: String } do |url:|
    WebSearch.fetch(url)
  end
end