# frozen_string_literal: true

require 'socket'

class Mnemosyne
  # Atlas -- the cartographer/curator of Mnemosyne. Complete project mapping,
  # woven into the cascade: after every Corpus sounding/sync the cartographer
  # (re-)mints compact `map` notes (Stufe 1 -- durable current-state maps, one
  # per project area plus an overview) and, for sync deltas, transient
  # fragments (Stufe 2 -- the change glows in recall with freshness weighting,
  # then decays into the corpus substrate). The map's one-line area
  # descriptions are written by the kopist (fast model) when a distinct fast
  # model exists (Mnemosyne.flash_available?(:map)); otherwise a heuristic
  # fallback writes them. Config: .aethercodex `cartography:` section
  # (auto_map / delta_fragments / fragment_ttl / map_flash / git_track / observe_edits / sync_marker).
  class Atlas
    MAP_TAG = 'map'
    DELTA_TAG = 'corpus-delta'

    class << self
      # Entry point invoked by Corpus.sound!/sync! -- config-gated weaving.
      # Returns { kind:, fragments:, notes:, promoted: } for the caller's
      # report. After a sync delta, Ouroboros' promotion ladder checks
      # whether any path glowed often enough to be lifted into a durable
      # structure note (fragment -> note rung of the cascade).
      def weave!(kind:, report: nil)
        fragments = 0
        if report && cartography[:delta_fragments]
          fragments = delta_fragments!(report)
          fragments += marker_fragment!(report) if fragments.positive? && cartography[:sync_marker]
        end
        notes = cartography[:auto_map] ? map! : 0
        promoted = (kind == :sync && report) ? Ouroboros.promote! : 0
        { kind: kind, fragments: fragments, notes: notes, promoted: promoted }
      end

      def cartography
        CONFIG.respond_to?(:cartography) ? CONFIG.cartography : {}
      end

      # -- Stufe-2 fusion: the transient cascade mirrors the project's living
      # change. One TTL fragment per touched file + one delta summary -- both
      # glow fresh in recall_fragments and decay toward the substrate.
      def delta_fragments!(report)
        count = 0
        ttl = cartography[:fragment_ttl] || Fragments::DEFAULT_TTL
        report[:added].each do |info|
          Fragments.fragment(
            content: "Δ added #{info[:rel]} — re-sounded, #{info[:symbols]} symbols (#{info[:language]})",
            tags: [DELTA_TAG, 'structure', 'code'],
            links: [info[:rel]], ttl: ttl
          )
          count += 1
        end
        report[:changed].each do |info|
          Fragments.fragment(
            content: "Δ changed #{info[:rel]} — re-sounded, #{info[:symbols]} symbols (#{info[:language]})",
            tags: [DELTA_TAG, 'structure', 'code'],
            links: [info[:rel]], ttl: ttl
          )
          count += 1
        end
        report[:removed].each do |info|
          Fragments.fragment(
            content: "Δ removed #{info[:rel]} — excised from the corpus graph",
            tags: [DELTA_TAG, 'structure', 'code'],
            links: [info[:rel]], ttl: ttl
          )
          count += 1
        end
        if count.positive?
          Fragments.fragment(
            content: "Project delta: +#{report[:added].size} added, #{report[:changed].size} changed, " \
                     "-#{report[:removed].size} removed (#{report[:unchanged]} unchanged) — " \
                     "woven at #{Time.now.strftime('%H:%M')}",
            tags: [DELTA_TAG, 'structure'],
            ttl: ttl
          )
          count += 1
        end
        count
      end

      # -- Cross-worker whisper: a sync-marker fragment announces the delta to
      # every sibling AetherOracle instance sharing this memory db. It glows
      # (freshness) and decays (TTL) like any Stufe-2 fragment -- recall in
      # another worker surfaces "something changed over there" without that
      # worker re-scanning anything.
      def marker_fragment!(report)
        worker = begin
          "#{Socket.gethostname}:#{Process.pid}"
        rescue StandardError
          'aether-worker'
        end
        Fragments.fragment(
          content: "sync-marker #{worker} @ #{Time.now.strftime('%m-%d %H:%M')}: +#{report[:added].size} added, " \
                   "#{report[:changed].size} changed, -#{report[:removed].size} removed — woven into the shared æther",
          tags: [DELTA_TAG, 'sync-marker', 'structure'],
          links: (report[:added] + report[:changed] + report[:removed]).map { |i| i[:rel] }.first(12),
          ttl: cartography[:fragment_ttl] || Fragments::DEFAULT_TTL
        )
        1
      end

      # -- Stufe-1 map: delete previous map notes, re-mint from the corpus.
      # Idempotent; returns { notes:, areas:, flash: }.
      def map!
        removed = Notes.remove_by_tag(MAP_TAG)
        groups = Corpus.map_groups
        lines, used_flash = one_liners(groups)
        total_files = groups.values.sum { |g| g[:files].size }
        total_symbols = groups.values.sum { |g| g[:symbols] }
        name = (defined?(CONFIG) && CONFIG.respond_to?(:project_name) && CONFIG.project_name) || 'project'
        overview = "Atlas map (#{name}): #{total_files} files, #{total_symbols} symbols, #{groups.size} areas — " \
                   "#{groups.keys.first(8).join(', ')}" \
                   "#{groups.size > 8 ? ", +#{groups.size - 8} more" : ''}"
        Notes.remember(content: overview,
                       tags: [MAP_TAG, 'structure', 'overview'],
                       links: groups.keys.map { |area| area == '(root)' ? '.' : area })
        groups.each do |area, g|
          line = lines[area] || "#{area}/ — #{g[:files].size} files, #{g[:symbols]} symbols"
          Notes.remember(
            content: "#{line} — samples: #{g[:samples].map { |p| File.basename(p) }.join(', ')}",
            tags: [MAP_TAG, 'structure', "map:#{area}"],
            links: g[:samples]
          )
        end
        { notes: groups.size + 1, areas: groups.size, flash: used_flash, removed_maps: removed }
      end

      def one_liners(groups)
        return [{}, false] if groups.empty?

        if Mnemosyne.flash_available?(:map) && cartography[:map_flash]
          lines = flash_one_liners(groups)
          return [lines, true] if lines.any?
        end
        [heuristic_one_liners(groups), false]
      end

      def heuristic_one_liners(groups)
        groups.each_with_object({}) do |(area, g), h|
          subs = g[:files].map { |p| p.split('/')[1] }.uniq.compact.first(4)
          h[area] = "#{area}/ — #{g[:files].size} files, #{g[:symbols]} symbols" \
                    "#{subs.any? ? " (#{subs.join(', ')})" : ''}"
        end
      end

      # The kopist writes the map: one line per area, current-state only.
      # Best-effort -- any failure falls back to the heuristic lines.
      def flash_one_liners(groups)
        listing = groups.map do |area, g|
          "#{area}: #{g[:files].size} files (#{g[:samples].map { |p| File.basename(p) }.join(', ')})"
        end.join("\n")
        prompt = "You are mapping a code repository. For each project area below, write ONE concise " \
                 "line describing what the area contains (current-state only, no history). Format exactly: " \
                 "\"<area>/ — <description>\". One line per area, no markdown.\n#{listing}"
        out = Conduit.flash([{ role: 'user', content: prompt }], max_tokens: 600, temperature: 0.2)
        return {} if out.nil? || out.strip.empty?

        groups.keys.each_with_object({}) do |area, h|
          line = out.lines.map(&:strip).find { |l| l.start_with?("#{area}/", "#{area} ") }
          h[area] = line if line
        end
      end
    end
  end
end