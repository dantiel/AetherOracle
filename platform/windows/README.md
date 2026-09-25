# windows — spec (WinUI3, C#)

Implement the `platform/README.md` contract in C#:

- **File permissions** — NTFS ACLs + packaged `AppContainer` capabilities
  (`broadFileSystemAccess`) → `OraclePermissionState`.
- **Daemon lifecycle** — `CreateProcess` (or a Win32 service) for
  `ruby/standalone_daemon.rb`; `canRunDaemon == true`.

Starts when the WinUI3 shell begins.
