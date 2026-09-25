# frozen_string_literal: true

class Mnemosyne
  # SealLedger — Salomo Rex' Tempel. The executive substrate above the task engine.
  # A SEAL is a plan: a goal + an ordered set of milestones, each delegated to a
  # companion (owner) and gated by dependency edges (depends_on). It answers the
  # question the task ledger alone cannot: *was zuerst, und wer?*
  #
  # One companion, two hands: Salomo is still a voice in Pythia (the veil), but his
  # FÄHIGKEIT lives here — a persistent plan the Siegelkabinett panel reads and he
  # describes. Correspondence, not duplication: milestones are real tasks (the same
  # engine `execute_task` drives), the seal merely orders and delegates them.
  class SealLedger
    class << self
      # Create a seal and its milestone tasks. `milestones` is an array of hashes:
      #   { title:, plan:, owner:, workflow_type:, depends_on: [indices] }
      # `depends_on` holds 0-based indices into `milestones`; edges are resolved to
      # task ids after all milestones exist (indices are stable, ids are not).
      def create_seal(goal:, description: nil, milestones: [])
        db = Mnemosyne.db
        db.execute 'INSERT INTO seals (goal, description, status) VALUES (?, ?, ?)',
                   [goal, description.to_s, 'active']
        seal_id = db.last_insert_row_id

        ids = {}
        Array(milestones).each_with_index do |m, i|
          m = symbolize(m)
          id = create_milestone(
            seal_id:        seal_id,
            title:          m[:title] || "Milestone #{i + 1}",
            plan:           m[:plan] || m[:title].to_s,
            owner:          m[:owner],
            workflow_type:  m[:workflow_type] || 'simple',
            milestone_order: i + 1
          )
          ids[i] = id
        end

        Array(milestones).each_with_index do |m, i|
          m = symbolize(m)
          deps = Array(m[:depends_on]).map { |idx| ids[idx.to_i] }.compact
          db.execute 'UPDATE tasks SET depends_on = ? WHERE id = ?', [deps.to_json, ids[i]]
        end

        seal_status(seal_id)
      end

      def list_seals
        Mnemosyne.db.execute('SELECT * FROM seals ORDER BY updated_at DESC, id DESC')
                    .map { |r| r.transform_keys(&:to_sym) }
      end

      def seal(seal_id)
        row = Mnemosyne.db.execute('SELECT * FROM seals WHERE id = ?', [seal_id]).first
        row&.transform_keys(&:to_sym)
      end

      # The executive snapshot: the seal + its ordered milestones (with parsed
      # dependency edges) + the computed next unblocked action and progress.
      def seal_status(seal_id)
        seal_row = seal(seal_id)
        return { error: "Seal #{seal_id} not found" } unless seal_row

        milestones = Mnemosyne.db.execute(
          'SELECT * FROM tasks WHERE seal_id = ? ORDER BY milestone_order ASC, id ASC',
          [seal_id]
        ).map do |r|
          r.transform_keys(&:to_sym).tap { |h| h[:depends_on] = Mnemosyne.safe_parse_json(h[:depends_on], []) }
        end

        done = milestones.select { |m| m[:status].to_s == 'completed' }.map { |m| m[:id] }
        completed = done.size
        runnable = milestones.find { |m| runnable?(m, done) }
        blocked  = !runnable && milestones.any? { |m| m[:status].to_s != 'completed' && m[:status].to_s != 'failed' }

        {
          seal:       seal_row,
          milestones: milestones,
          next:       runnable,
          blocked:    blocked,
          progress:   {
            completed: completed,
            total:     milestones.size,
            ratio:     milestones.empty? ? 0.0 : (completed.to_f / milestones.size).round(2)
          }
        }
      end

      # Delegate a milestone to a companion (owner glyph). A soft-validate against
      # the pantheon when loaded; unknown glyphs are still stored — the seal is a
      # ledger, not a gatekeeper.
      def delegate(task_id, owner)
        Mnemosyne.db.execute 'UPDATE tasks SET owner = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
                             [owner.to_s, task_id]
        Mnemosyne.db.execute('SELECT * FROM tasks WHERE id = ?', [task_id]).first&.transform_keys(&:to_sym)
      end

      def update_seal(seal_id, goal: nil, description: nil, status: nil)
        fields = []
        values = []
        { goal: goal, description: description, status: status }.compact.each do |k, v|
          fields << "#{k} = ?"
          values << v
        end
        return seal(seal_id) if fields.empty?

        Mnemosyne.db.execute "UPDATE seals SET #{fields.join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                             [*values, seal_id]
        seal(seal_id)
      end

      private

      def create_milestone(seal_id:, title:, plan:, owner:, workflow_type:, milestone_order:)
        Mnemosyne::TaskLedger.manage_tasks(
          action:          'create',
          title:           title,
          plan:            plan,
          workflow_type:   workflow_type,
          owner:           owner,
          seal_id:         seal_id,
          milestone_order: milestone_order
        )['id']
      end

      def runnable?(milestone, done)
        return false if %w[completed failed].include?(milestone[:status].to_s)

        (Array(milestone[:depends_on]) - done).empty?
      end

      def symbolize(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
