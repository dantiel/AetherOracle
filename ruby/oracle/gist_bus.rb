# frozen_string_literal: true

require 'securerandom'

# GistBus — the flow-event bus for concurrent companion flows.
#
# One brain, many eyes: when several companions (or the main oracle and the task
# engine) run at once, each flow publishes a *gist* — the public silhouette of
# its work — while keeping its reasoning and tool bodies veiled. The bus is the
# shared substrate those gists travel over.
#
# Lifecycle events:
#   :inception   a flow began (who, when, its Aegis summary — no notes)
#   :conclusion  a flow finished (its answer merges into the normal flow)
#
# The bus also carries *broadcasts*: user messages that every relevant flow must
# see in its conduit — addressed to all, or narrowed to one companion.
#
# Source Veil, applied to an agent society: what is *finished* is public; what
# is *unfinished* stays veiled. A flow shares its intent + aegis (inception) and
# its answer (conclusion) — never its tool bodies or partial reasoning. This
# keeps the share cost O(N) (a few dozen tokens per sibling) instead of O(N²)
# (full foreign histories), so concurrency stays legible without exploding.
module GistBus
  # Ring-buffer ceiling: broadcasts beyond this evaporate (token economy).
  MAX_BROADCASTS = 20

  @flows = {}      # id => {id:, kind:, label:, companion:, project:, started_at:, aegis:, status:}
  @broadcasts = [] # {id:, at:, author:, target:, content:}
  @mutex = Mutex.new

  class << self
    def begin_flow(id:, kind: :oracle, label: 'Pythia', companion: nil, project: nil)
      entry = {
        id:, kind:, label:, companion: companion&.to_s, project: project.to_s,
        started_at: Time.now, aegis: '', status: :running
      }
      @mutex.synchronize { @flows[id] = entry }
      entry
    end

    def set_aegis(id, summary)
      @mutex.synchronize { @flows[id][:aegis] = summary.to_s.strip if @flows[id] }
    end

    def end_flow(id)
      @mutex.synchronize { @flows.delete(id) }
      nil
    end

    # Sibling flows still running, excluding the caller and foreign projects.
    def running(exclude_id: nil, project: nil)
      @mutex.synchronize do
        @flows.values.select do |f|
          f[:status] == :running &&
            f[:id] != exclude_id &&
            (project.to_s.empty? || f[:project] == project.to_s)
        end
      end
    end

    def broadcast(content:, author: 'user', target: nil)
      entry = {
        id: SecureRandom.hex(6), at: Time.now, author: author.to_s,
        target: target&.to_s, content: content.to_s
      }
      @mutex.synchronize do
        @broadcasts << entry
        @broadcasts.shift while @broadcasts.length > MAX_BROADCASTS
      end
      entry
    end

    def broadcasts
      @mutex.synchronize { @broadcasts.dup }
    end

    # The conduit block for a flow: running sibling flows (start time + aegis,
    # no notes) plus the broadcasts this flow is allowed to see. Returns nil
    # when there is nothing to say — the conduit stays silent, not padded.
    def conduit_block(exclude_id: nil, project: nil, companion: nil)
      flows = running(exclude_id: exclude_id, project: project)
      msgs = visible_broadcasts(companion)
      return nil if flows.empty? && msgs.empty?

      parts = []
      unless flows.empty?
        lines = flows.map do |f|
          aegis = f[:aegis].empty? ? '' : " — #{f[:aegis]}"
          "- #{f[:label]} (#{f[:kind]}) started #{f[:started_at].strftime('%H:%M:%S')}#{aegis}"
        end
        parts << "CONCURRENT FLOWS (still running):\n#{lines.join("\n")}"
      end
      unless msgs.empty?
        lines = msgs.map do |m|
          target = m[:target] && !m[:target].empty? ? " → #{m[:target]}" : ' → all'
          "- [#{m[:at].strftime('%H:%M:%S')}] #{m[:author]}#{target}: #{m[:content]}"
        end
        parts << "GLOBAL BROADCAST (react if relevant):\n#{lines.join("\n")}"
      end
      parts.join("\n\n")
    end

    private

    def visible_broadcasts(companion)
      companion = companion.to_s
      broadcasts.select { |m| m[:target].to_s.empty? || m[:target] == companion }
    end
  end
end
