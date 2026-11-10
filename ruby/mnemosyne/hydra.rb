# frozen_string_literal: true

require 'socket'
require 'securerandom'

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
        "#{host}-#{Process.pid}-#{SecureRandom.hex(4)}"
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
          [session_id.to_s, label.to_s, role.to_s, project.to_s, port, pid.to_i]
        session_id.to_s
      rescue StandardError
        nil
      end

      # Refresh a session's heartbeat. `aegis_summary` (when given) updates the
      # registry's cached silhouette of that session's current orientation.
      def heartbeat(session_id: nil, aegis_summary: nil)
        sid = session_id || Mnemosyne.current_session_id
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
    end
  end
end