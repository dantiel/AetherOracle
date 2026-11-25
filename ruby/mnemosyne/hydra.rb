# frozen_string_literal: true

require 'socket'
require 'securerandom'
require 'json'

class Mnemosyne
  # Hydra — the session system: a persistent registry of heads (sessions)
  # breathing one shared Aegis heart.
  #
  # One project, many heads: every AetherOracle process — a daemon, a chamber,
  # a task runner, a native editor, or a HydraTerminal — that breathes the same
  # `.aether/mnemosyne.db` registers itself here as a *head* (a session). The
  # Aegis is the shared *heart* — a single append-only row that every process
  # restores on boot; Hydra is the *roster of heads* breathing that heart, so a
  # newly-opened session sees its siblings instead of a private copy of the
  # æther. A head == a session; they are one and the same.
  #
  # The TMUX (HydraTerminal, ruby/oracle/hydra_terminal.rb) is just one
  # graphical *frontend* onto this session system. Native editors, the CLI
  # chamber, and the daemon all speak to the same Hydra substrate.
  #
  # Correspondence, not duplication: the Aegis holds the *what* (the course),
  # Hydra holds the *who* (the heads), and every Aegis write refreshes the
  # writer's own registry row — so the shared Aegis and the head roster
  # synchronize through the same substrate.
  class Hydra
    STALE_AFTER    = 120   # seconds without a heartbeat → considered gone
    PRUNE_AFTER    = 3600  # seconds → hard-delete the orphaned row
    HEARTBEAT_EVERY = 30   # seconds between automatic daemon heartbeats

    class << self
      # A stable, per-process identity: host + pid + a random boot token, so
      # restarts and multiple shells never collide on the same registry row.
      def generate_id
        host = Socket.gethostname.to_s.gsub(/[^a-zA-Z0-9_-]/, '-')[0, 24]
        # Session ids are pure ASCII, but the sqlite3 gem binds an ASCII-8BIT
        # (BINARY-encoded) String as a BLOB. A BLOB session_id never `=` a TEXT
        # literal/bind, so `fetch_history(session_id:)` and `load_state` silently
        # miss the row. Force UTF-8 so every write lands as TEXT.
        "#{host}-#{Process.pid}-#{SecureRandom.hex(4)}".force_encoding(Encoding::UTF_8)
      end

      # JSON round-trips stringify symbol keys; the Oracle's resume_state
      # expects symbols, so resurrected state must be deep-symbolized.
      def deep_symbolize(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
        when Array then obj.map { |v| deep_symbolize(v) }
        else obj
        end
      end

      # Coerce an arbitrary resume_state into a JSON-safe graph before
      # serialization: symbol keys → strings, Time-like values → iso8601, and
      # anything else non-primitive → its string form. Guarantees `JSON.generate`
      # never raises on a stray Time/object inside `arts` or `tool_results`.
      def serialize_state(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_s] = serialize_state(v) }
        when Array
          obj.map { |v| serialize_state(v) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          obj
        else
          obj.respond_to?(:iso8601) ? obj.iso8601 : obj.to_s
        end
      end

      # Insert or refresh a session row. Idempotent — a context switch (or a
      # daemon restart) re-registers the same process id onto the new project's
      # db without leaving a ghost row behind.
      def register(session_id:, label: nil, role: 'oracle', project: nil,
                   port: nil, pid: nil)
        pid ||= Process.pid
        Mnemosyne.db.execute <<~SQL,
          INSERT INTO aether_sessions
            (session_id, label, role, project, port, pid, status, started_at, last_seen)
          VALUES (?, ?, ?, ?, ?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          ON CONFLICT(session_id) DO UPDATE SET
            label      = excluded.label,
            role       = excluded.role,
            project    = excluded.project,
            port       = excluded.port,
            pid        = excluded.pid,
            status     = 'active',
            last_seen  = CURRENT_TIMESTAMP
        SQL
          [session_id.to_s.force_encoding(Encoding::UTF_8), label.to_s, role.to_s, project.to_s, port, pid.to_i]
        session_id.to_s
      rescue StandardError
        nil
      end

      # Refresh a session's heartbeat. `aegis_summary` (when given) updates the
      # registry's cached silhouette of that session's current orientation.
      def heartbeat(session_id: nil, aegis_summary: nil)
        sid = session_id || Mnemosyne.current_session_id
        sid = sid.to_s.force_encoding(Encoding::UTF_8) if sid
        return nil if sid.nil? || sid.to_s.empty?

        if aegis_summary
          Mnemosyne.db.execute(<<~SQL, [aegis_summary.to_s, sid.to_s])
            UPDATE aether_sessions
               SET last_seen = CURRENT_TIMESTAMP,
                   aegis_summary = ?,
                   status = 'active'
             WHERE session_id = ?
          SQL
        else
          Mnemosyne.db.execute(<<~SQL, [sid.to_s])
            UPDATE aether_sessions
               SET last_seen = CURRENT_TIMESTAMP,
                   status = 'active'
             WHERE session_id = ?
          SQL
        end
        sid.to_s
      rescue StandardError
        nil
      end

      # Mark a session closed (its process is shutting down or switching project).
      def close(session_id: nil)
        sid = session_id || Mnemosyne.current_session_id
        sid = sid.to_s.force_encoding(Encoding::UTF_8) if sid
        return nil if sid.nil? || sid.to_s.empty?

        Mnemosyne.db.execute(<<~SQL, [sid.to_s])
          UPDATE aether_sessions
             SET status = 'closed', last_seen = CURRENT_TIMESTAMP
           WHERE session_id = ?
        SQL
        sid.to_s
      rescue StandardError
        nil
      end

      # Sessions currently breathing this project's æther: active and seen
      # within the heartbeat window. The cutoff is computed in SQLite's own
      # clock (`datetime('now', …)`) so local/UTC skew can never drop a peer.
      def active_sessions(project: nil, within: STALE_AFTER, exclude: nil)
        conditions = ["status = 'active'", "last_seen >= datetime('now', ?)"]
        params = ["-#{within.to_i} seconds"]

        unless project.to_s.empty?
          conditions << 'project = ?'
          params << project.to_s
        end
        unless exclude.to_s.empty?
          conditions << 'session_id != ?'
          params << exclude.to_s
        end

        sql = "SELECT session_id, label, role, project, port, pid, " \
              "aegis_summary, status, started_at, last_seen " \
              "FROM aether_sessions WHERE #{conditions.join(' AND ')} " \
              "ORDER BY last_seen DESC"

        Mnemosyne.db.execute(sql, params).map { |r| r.transform_keys(&:to_sym) }
      rescue StandardError => e
        warn "[Hydra] active_sessions failed: #{e.class}: #{e.message}"
        []
      end

      # Hard-delete rows whose process has been silent past the prune horizon.
      def prune!
        Mnemosyne.db.execute(<<~SQL, ["-#{PRUNE_AFTER} seconds"])
          DELETE FROM aether_sessions
           WHERE status = 'closed'
              OR last_seen < datetime('now', ?)
        SQL
      rescue StandardError => e
        warn "[Hydra] prune! failed: #{e.class}: #{e.message}"
        nil
      end

      # Every session row in this project's æther — active, stale AND closed —
      # with a computed age and an effective status. `active_sessions` hides
      # anything silent past the heartbeat window; this is the debug view that
      # surfaces the invisible: orphaned rows from crashed processes still
      # stamped 'active' but long dead. `stale` = alive past STALE_AFTER.
      def all_sessions(project: nil, exclude: nil, hide_empty: false)
        conditions = []
        params = []

        unless project.to_s.empty?
          conditions << 'project = ?'
          params << project.to_s
        end
        unless exclude.to_s.empty?
          conditions << 'session_id != ?'
          params << exclude.to_s
        end
        if hide_empty
          conditions << "state_json IS NOT NULL AND state_json != ''"
        end

        where = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"
        sql = <<~SQL
          SELECT session_id, label, role, project, port, pid,
                 aegis_summary, status, started_at, last_seen,
                 CAST((julianday('now') - julianday(last_seen)) * 86400 AS INTEGER) AS age_seconds,
                 CASE WHEN state_json IS NULL OR state_json = '' THEN 0 ELSE 1 END AS resumable
            FROM aether_sessions
            #{where}
           ORDER BY last_seen DESC
        SQL

        Mnemosyne.db.execute(sql, params).map do |r|
          r = r.transform_keys(&:to_sym)
          age = r[:age_seconds].to_i
          r[:age_seconds] = age
          r[:stale] = r[:status] == 'active' && age > STALE_AFTER
          r[:effective_status] = r[:stale] ? 'stale' : r[:status]
          r[:resumable] = r[:resumable].to_i == 1
          r
        end
      rescue StandardError => e
        warn "[Hydra] all_sessions failed: #{e.class}: #{e.message}"
        []
      end

      # Force-remove a session row (crashed head, orphaned editor, stuck slot).
      # Hard delete — unlike `close`, which only stamps status='closed'.
      def kick!(session_id:)
        sid = session_id.to_s.force_encoding(Encoding::UTF_8)
        return nil if sid.empty?

        Mnemosyne.db.execute('DELETE FROM aether_sessions WHERE session_id = ?', [sid])
        sid
      rescue StandardError => e
        warn "[Hydra] kick! failed: #{e.class}: #{e.message}"
        nil
      end

      # Terminate the OS process owning a pid. Windows → `taskkill /F /PID`,
      # everywhere else → SIGKILL. Returns true when the kill was issued (the
      # process may already have been gone — that still means "not running").
      def terminate_pid(pid)
        pid = pid.to_i
        return false if pid <= 0

        if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
          system('taskkill', '/F', '/PID', pid.to_s, out: File::NULL, err: File::NULL)
          $?.success?
        else
          Process.kill('KILL', pid)
          true
        end
      rescue Errno::ESRCH, Errno::EPERM, StandardError
        false
      end

      # Kill a session for real: terminate its owning OS process (by pid), then
      # hard-delete the registry row. Unlike `kick!` (row only) or `close`
      # (status stamp only), this silences the head itself. Refuses to kill the
      # calling process. Returns an outcome hash, or nil when the row is missing.
      def kill!(session_id:)
        sid = session_id.to_s
        return nil if sid.empty?

        row = Mnemosyne.db.execute(
          'SELECT session_id, pid FROM aether_sessions WHERE session_id = ?', [sid]
        ).first
        return nil unless row

        pid = row['pid'].to_i
        if pid == Process.pid
          return { session_id: sid, pid: pid, terminated: false, skipped: true }
        end

        terminated = terminate_pid(pid)
        kick!(session_id: sid)
        { session_id: sid, pid: pid, terminated: terminated }
      rescue StandardError => e
        warn "[Hydra] kill! failed: #{e.class}: #{e.message}"
        nil
      end

      # Persist a session's durable runtime state — its mid-flight Oracle
      # resume_state (messages / tool_results / arts / answer) — as JSON on the
      # registry row, so a crash can be resumed seamlessly. `state: nil` clears
      # the snapshot (a clean turn leaves nothing in flight). Also refreshes the
      # heartbeat, since a checkpoint implies the head is alive.
      def save_state(session_id:, state: nil)
        sid = session_id.to_s.force_encoding(Encoding::UTF_8)
        return nil if sid.empty?

        json = state.nil? ? nil : JSON.generate(serialize_state(state))
        Mnemosyne.db.execute(<<~SQL, [json, sid])
          UPDATE aether_sessions
             SET state_json = ?,
                 last_seen = CURRENT_TIMESTAMP,
                 status = 'active'
           WHERE session_id = ?
        SQL
        sid
      rescue StandardError => e
        warn "[Hydra] save_state failed: #{e.class}: #{e.message}"
        nil
      end

      # Read a session's durable state back (the last persisted resume_state),
      # or nil when the row is missing or carries no snapshot.
      def load_state(session_id:)
        sid = session_id.to_s.force_encoding(Encoding::UTF_8)
        return nil if sid.empty?

        row = Mnemosyne.db.execute(
          'SELECT state_json FROM aether_sessions WHERE session_id = ?', [sid]
        ).first
        return nil unless row

        deep_symbolize(Mnemosyne.safe_parse_json(row['state_json'], nil))
      rescue StandardError => e
        warn "[Hydra] load_state failed: #{e.class}: #{e.message}"
        nil
      end

      # "Proceed" a crashed/closed session: re-adopt its identity in the current
      # process, restore its durable state, and stamp it active again. Returns
      # the resurrected session row (state under :state), ready for the caller
      # to continue seamlessly. The dead pid is replaced by the adopting
      # process, so the row is genuinely alive again.
      def proceed(session_id:)
        sid = session_id.to_s.force_encoding(Encoding::UTF_8)
        return nil if sid.empty?

        row = Mnemosyne.db.execute(
          'SELECT session_id, label, role, project, port, pid, aegis_summary, ' \
          'status, started_at, last_seen, state_json ' \
          'FROM aether_sessions WHERE session_id = ?', [sid]
        ).first
        return nil unless row
        row = row.transform_keys(&:to_sym)

        state = deep_symbolize(Mnemosyne.safe_parse_json(row[:state_json], nil))

        # Re-adopt the identity (register refreshes last_seen + status, and
        # swaps in this process's pid) while preserving the durable state.
        register(session_id: sid,
                 label: row[:label], role: row[:role], project: row[:project],
                 port: row[:port], pid: nil)
        save_state(session_id: sid, state: state) if state

        row[:state] = state
        row[:status] = 'active'
        row
      rescue StandardError => e
        warn "[Hydra] proceed failed: #{e.class}: #{e.message}"
        nil
      end

      # Crashed heads: rows still stamped 'active' but silent past the heartbeat
      # window — orphans whose process died without a graceful close. These are
      # the candidates `proceed` can resurrect.
      def stale_sessions(project: nil, exclude: nil)
        all_sessions(project: project, exclude: exclude).select { |s| s[:stale] }
      end

      # Resume every crashed session at once. Returns the resurrected roster,
      # each with its restored state.
      def proceed_stale(project: nil, exclude: nil)
        stale_sessions(project: project, exclude: exclude).map do |s|
          proceed(session_id: s[:session_id])
        end.compact
      end

      # A compact, token-cheap line for the conduit/orientation: the roster of
      # sibling sessions, each with its current Aegis silhouette.
      def summary_line(project: nil, exclude: nil, max_aegis: 80)
        sessions = active_sessions(project: project, exclude: exclude)
        return nil if sessions.empty?

        parts = sessions.map do |s|
          name = s[:label].to_s.strip
          name = s[:session_id].to_s if name.empty?
          aegis = s[:aegis_summary].to_s.strip
          aegis.empty? ? name : "#{name} — #{aegis[0, max_aegis]}"
        end
        "CONCURRENT SESSIONS (#{sessions.size}): #{parts.join(' | ')}"
      end

      # The red thread's roster lens: recent sessions (live first, then
      # recently silent/closed), each with its last-known course. Unlike
      # `summary_line` (live siblings only), this surfaces what a *finished or
      # orphaned* sibling was last working on — so a fresh head can pick up the
      # thread without being re-told. `all_sessions` already sorts last_seen
      # DESC, so the freshest rows are windowed; each is tagged live/stale/closed.
      def thread_block(project: nil, exclude: nil, limit: 6, max_aegis: 100)
        rows = all_sessions(project: project, exclude: exclude).first(limit.to_i)
        return nil if rows.empty?

        live = rows.select { |s| s[:effective_status] == 'active' }
        gone = rows.reject { |s| s[:effective_status] == 'active' }

        blocks = []
        unless live.empty?
          lines = live.map do |s|
            name = s[:label].to_s.strip
            name = s[:session_id].to_s if name.empty?
            aegis = s[:aegis_summary].to_s.strip
            "  - #{name}#{aegis.empty? ? '' : " — #{aegis[0, max_aegis]}"}"
          end
          blocks << "SIBLING SESSIONS — live (#{live.size}):\n#{lines.join("\n")}"
        end

        unless gone.empty?
          lines = gone.map do |s|
            name = s[:label].to_s.strip
            name = s[:session_id].to_s if name.empty?
            status = s[:effective_status] == 'stale' ? 'stale' : 'closed'
            aegis = s[:aegis_summary].to_s.strip
            "  - #{name} [#{status}]#{aegis.empty? ? '' : " — #{aegis[0, max_aegis]}"}"
          end
          blocks << "SIBLING SESSIONS — recently silent/closed (#{gone.size}):\n#{lines.join("\n")}"
        end

        blocks.join("\n") unless blocks.empty?
      end
    end
  end
end