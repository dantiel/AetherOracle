# frozen_string_literal: true

require 'net/http'
require 'json'
require_relative 'config'

# ÆtherLink — the bridge between contexts.
# Discovers peer AetherCodex servers on localhost (ports 4550–4610)
# and provides cross-context querying, metempsychosis, and task spawning.
#
# === Hermetic Principle: Correspondence ===
# As each context mirrors the whole, so does the Link mirror each context —
# a resonant network where every node reflects and transforms every other.
module AetherLink
  SCAN_RANGE = (4550..4610).freeze
  HEARTBEAT_PATH = '/aether/heartbeat'.freeze
  CONNECT_TIMEOUT = 2
  READ_TIMEOUT = 120 # Oracle invocations can take significant reasoning time

  @known_contexts = {}
  @mutex = Mutex.new

  class << self
    attr_reader :known_contexts

    # Stable, human-authored context annotations from .aethercodex (`contexts:`).
    # Keyed by context name; values carry :port, :description, :tags.
    def annotated_contexts
      CONFIG.contexts
    rescue StandardError
      {}
    end

    # Scan localhost ports for peer AetherCodex servers.
    # Calls GET /aether/heartbeat on each candidate and registers responders.
    # Skips own port. Marks unreachable contexts as stale.
    def discover!
      @mutex.synchronize do
        # Mark all previously-known entries stale; they are refreshed below if
        # still reachable. Non-annotated stale entries are pruned at the end —
        # this drops renamed/stopped peers instead of accumulating duplicates.
        @known_contexts.each_value { |c| c[:stale] = true }

        SCAN_RANGE.each do |port|
          next if port == own_port

          info = heartbeat_from(port) or next
          name = info[:name] || info['name'] or next

          @known_contexts[name] = {
            port:         port,
            path:         info[:path] || info['path'],
            capabilities: info[:capabilities] || info['capabilities'] || [],
            version:      info[:version] || info['version'],
            busy:         info[:busy] || info['busy'] || false,
            active_tasks: info[:active_tasks] || info['active_tasks'] || [],
            last_seen:    Time.now,
            stale:        false
          }
        end
        apply_annotations!
        prune_stale!
      end
      @known_contexts
    end

    # Look up a peer context by name.
    def lookup(name)
      @known_contexts[name]
    end

    # POST a JSON payload to a peer context's endpoint.
    # Returns parsed response body (symbolized keys) or nil on failure.
    # Stale contexts are marked and returned nil.
    # Lazily discovers peers if none known — first cross-context call triggers scan.
    def query(context_name, endpoint, payload = {})
      discover! if @known_contexts.empty?
      ctx = lookup(context_name)
      # Annotations (`.aethercodex` `contexts:`) may be added after the last
      # discovery and alias friendly names to ports. Re-scan once on a miss so
      # newly-annotated peers resolve on first use instead of "unreachable".
      if ctx.nil?
        discover!
        ctx = lookup(context_name)
      end
      ctx or return nil

      uri = URI("http://127.0.0.1:#{ctx[:port]}#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = payload.to_json

      response = http.request(request)
      return nil unless response.code.to_i == 200

      JSON.parse(response.body, symbolize_names: true)
    rescue StandardError
      mark_stale(context_name)
      nil
    end

    # Check if a context is currently busy (oracle thinking / task executing).
    # Works for remote peers and the local context alike — if the name matches
    # own_name, queries the local heartbeat without going through the network.
    # Returns true/false, or nil if the context is unreachable.
    def busy?(context_name)
      if context_name == own_name
        info = heartbeat_from(own_port)
        return nil unless info
        return info[:busy] || false  # nil for old servers → false (reachable, not trackable)
      end

      discover! if @known_contexts.empty?
      ctx = lookup(context_name) or return nil
      info = heartbeat_from(ctx[:port])
      return nil unless info
      info[:busy] || false
    rescue StandardError
      nil
    end

    # Send a prompt or task to a peer context — only if it's not busy.
    # Returns { ok: true, answer:, html: } or { ok: false, error:, busy: }.
    def invoke(context_name, prompt:, type: 'chat', from_context: own_name,
               memory: nil, metempsychosis: false)
      response = query(context_name, '/aether/invoke',
                       { prompt: prompt, type: type, from_context: from_context,
                         memory: memory, metempsychosis: metempsychosis })
      return { ok: false, error: 'No response', busy: nil } unless response
      if response[:error]
        { ok: false, error: response[:error], busy: response[:busy] }
      else
        { ok: true }.merge(response)
      end
    end

    # Mark a context as stale (unreachable) — retried on next discover!
    def mark_stale(name)
      ctx = @known_contexts[name]
      ctx[:stale] = true if ctx
    end

    # The name this context advertises to peers. Prefers an explicit `name:`
    # in .aethercodex, else the project root folder name (TM_PROJECT_DIRECTORY)
    # — never the folder of the last-opened file.
    def own_name
      CONFIG.project_name
    end

    # The port this server runs on.
    def own_port
      ENV['AETHER_PORT']&.to_i || CONFIG.port
    end

    private

    # Drop entries that stayed stale after the scan and carry no annotation.
    # Reachable peers are refreshed above (stale=false); annotated peers are
    # re-registered by apply_annotations! (annotated=true) and must persist
    # even when offline. Everything else — renamed or stopped peers — dies here.
    def prune_stale!
      @known_contexts.delete_if { |_name, c| c[:stale] && !c[:annotated] }
    end

    # Overlay .aethercodex context annotations onto known_contexts.
    # - Same name (or same explicit port) → enrich the discovered entry.
    # - Unknown name → register as an annotated (stale/offline) entry.
    def apply_annotations!
      annotated_contexts.each do |name, ann|
        entry = @known_contexts[name]

        if entry.nil? && ann[:port]
          entry = @known_contexts.values.find { |c| c[:port] == ann[:port] }
          @known_contexts[name] = entry if entry
        end

        if entry
          entry[:description] = ann[:description] if ann[:description]
          entry[:tags]       = ann[:tags]       if ann[:tags]
          entry[:port]       = ann[:port]       if ann[:port] && entry[:port].nil?
          entry[:annotated]  = true
        else
          @known_contexts[name] = {
            port:         ann[:port],
            path:         nil,
            capabilities: [],
            version:      nil,
            busy:         false,
            active_tasks: [],
            last_seen:    nil,
            stale:        true,
            annotated:    true,
            description:  ann[:description],
            tags:         ann[:tags]
          }
        end
      end
    end

    # GET /aether/heartbeat on a given port, return parsed info or nil.
    def heartbeat_from(port)
      uri = URI("http://127.0.0.1:#{port}#{HEARTBEAT_PATH}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      response = http.get(uri.path)
      return nil unless response.code.to_i == 200

      JSON.parse(response.body, symbolize_names: true)
    rescue StandardError
      nil
    end
  end
end