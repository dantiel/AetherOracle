# frozen_string_literal: true

require_relative '../instrumentarium/metaprogramming_utils'

class Mnemosyne
  # AethernautManifest — Pythia's agenda.
  #
  # The ship is the *Argo*; the crew are the *aethernauts*. Every companion
  # suggestion that surfaces is not a transient popover but an INTENTION — a
  # sailor with a mission, signed into the ship's manifest. Here the companions
  # and the oracle meet on one deck: the æther is everywhere, and the agenda is
  # the shared course.
  #
  # One queue, many shapes (polymorphism, not a switch-statement appended later):
  # each intention carries a KIND, and each kind carries its own WORKER — the
  # action the oracle takes when the intention surfaces. A suggestion becomes a
  # surface; a recovery becomes a one-click reweave; a directive becomes an
  # execution; a ritual becomes a seal-run; a conjuration becomes a divination;
  # an insight becomes a note. The same manifest, the same aether, a different
  # body per intention.
  #
  # Aegis becomes Pythia's agenda: `Mnemosyne::Aegis.agenda` reads this manifest,
  # so the voice's schedule *is* the oracle's orientation. Companion intentions
  # act polymorphically while Aegis holds the course — aspect-driven aetheric
  # engineering: the work is decomposed into aspects (companion facets), and the
  # æther weaves their intentions back into one agenda.
  class AethernautManifest
    KINDS = {
      suggestion:  { label: 'Vorschlag',    glyph: '✨', default_action: 'suggest' },
      directive:   { label: 'Direktive',    glyph: '🎯', default_action: 'oracle' },
      recovery:    { label: 'Riss-Faden',   glyph: '🪡', default_action: 'recover_last_intent' },
      ritual:      { label: 'Ritual',       glyph: '🔮', default_action: 'seal_run' },
      conjuration: { label: 'Beschwörung',  glyph: '🌀', default_action: 'conjuration' },
      insight:     { label: 'Einsicht',     glyph: '💠', default_action: 'remember' }
    }.freeze

    ACTIVE_STATUSES = %w[pending active].freeze

    class << self
      # Sign a new intention into the manifest.
      def enqueue(kind:, title:, aspect: nil, glyph: nil, body: nil, action: nil,
                  payload: {}, priority: 0, source: nil)
        kind = kind.to_sym
        kind = :suggestion unless KINDS.key?(kind)
        glyph ||= KINDS[kind][:glyph]
        aspect = aspect.to_s.strip
        aspect = 'aegis' if aspect.empty?

        db = Mnemosyne.db
        db.execute <<~SQL,
          INSERT INTO aethernaut_manifest
            (kind, aspect, glyph, title, body, action, payload, status, priority, source, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
                    [kind.to_s, aspect, glyph, title.to_s, body.to_s,
                     (action || KINDS[kind][:default_action]).to_s,
                     JSON.generate(payload || {}), priority.to_i, source.to_s]
        find(db.last_insert_row_id)
      end

      # Companion convenience: a suggestion is the most common intention, and it
      # always carries the aspect (facet) that proposed it.
      def from_suggestion(aspect:, title:, body: nil, action: nil, payload: {}, priority: 0)
        enqueue(kind: :suggestion, aspect: aspect, title: title, body: body,
                action: action, payload: payload, priority: priority, source: "companion:#{aspect}")
      end

      def find(id)
        row = Mnemosyne.db.execute('SELECT * FROM aethernaut_manifest WHERE id = ?', [id]).first
        row && materialize(row)
      end

      # Pythia's agenda: the ordered course of intentions still awaiting action.
      def agenda(status: nil, limit: nil)
        statuses = Array(status || ACTIVE_STATUSES).map(&:to_s)
        placeholders = statuses.map { '?' }.join(', ')
        rows = Mnemosyne.db.execute(
          "SELECT * FROM aethernaut_manifest WHERE status IN (#{placeholders}) ORDER BY priority DESC, id ASC",
          statuses
        )
        rows = rows.first(limit.to_i) if limit
        rows.map { |r| materialize(r) }
      end

      # The next intention without consuming it.
      def peek
        agenda(limit: 1).first
      end

      # Consume the next intention: mark it active and return it, so it can act.
      def take
        next_intention = peek
        return nil unless next_intention

        Mnemosyne.db.execute(
          'UPDATE aethernaut_manifest SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
          ['active', next_intention[:id]]
        )
        find(next_intention[:id])
      end

      # The polymorphic heart: resolve an intention into the action its kind
      # demands. One manifest, many shapes — the aspect chooses its body here.
      def act(intention)
        intention = find(intention[:id]) if intention.is_a?(Hash) && intention[:id]
        return { type: :none } unless intention

        base = { type: intention[:kind].to_sym, intent_id: intention[:id],
                 glyph: intention[:glyph], title: intention[:title] }

        case intention[:kind].to_sym
        when :suggestion
          base.merge(action: intention[:action] || 'suggest', body: intention[:body], payload: intention[:payload])
        when :directive
          base.merge(action: intention[:action] || 'oracle', payload: intention[:payload])
        when :recovery
          base.merge(prompt: intention[:body] || intention[:title],
                     action: intention[:action] || 'recover_last_intent')
        when :ritual
          base.merge(action: intention[:action] || 'seal_run', task_id: intention[:payload]&.dig('task_id'),
                     seal_id: intention[:payload]&.dig('seal_id'))
        when :conjuration
          base.merge(prompt: intention[:body] || intention[:title],
                     action: intention[:action] || 'conjuration')
        when :insight
          base.merge(content: intention[:body] || intention[:title],
                     action: intention[:action] || 'remember')
        else
          base.merge(action: intention[:action])
        end
      end

      def complete(id)
        transition(id, 'done')
      end

      def dismiss(id, reason: nil)
        Mnemosyne.db.execute(
          'UPDATE aethernaut_manifest SET status = ?, payload = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
          ['dismissed', JSON.generate({ reason: reason.to_s }), id]
        )
        find(id)
      end

      def promote(id, priority)
        Mnemosyne.db.execute(
          'UPDATE aethernaut_manifest SET priority = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
          [priority.to_i, id]
        )
        find(id)
      end

      def count(status: nil)
        statuses = Array(status || ACTIVE_STATUSES).map(&:to_s)
        placeholders = statuses.map { '?' }.join(', ')
        Mnemosyne.db.get_first_value(
          "SELECT COUNT(*) FROM aethernaut_manifest WHERE status IN (#{placeholders})", statuses
        ).to_i
      end

      private

      def transition(id, status)
        Mnemosyne.db.execute(
          'UPDATE aethernaut_manifest SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
          [status.to_s, id]
        )
        find(id)
      end

      def materialize(row)
        h = row.transform_keys(&:to_sym)
        h[:kind] = h[:kind].to_sym
        h[:priority] = h[:priority].to_i
        h[:payload] = Mnemosyne.safe_parse_json(h[:payload], {})
        h
      end
    end
  end
end
