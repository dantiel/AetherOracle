# linux — spec (GTK, C/Rust)

Implement the `platform/README.md` contract in C/Rust:

- **File permissions** — POSIX mode bits + Flatpak/bubblewrap portals
  (document store) → `OraclePermissionState`.
- **Daemon lifecycle** — `fork`+`exec` (or a `systemd` socket unit) for
  `ruby/standalone_daemon.rb`; `canRunDaemon == true`.

Starts when the GTK shell begins.
