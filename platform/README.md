# AetherOracle — platform integration contract

The core is language-agnostic; the *integration* is per-OS. Each platform provides
exactly two capabilities, implemented in the language of that platform's shell
(Swift for darwin/ios, C# for WinUI3, C/Rust for GTK). These are the seams where a
portable core touches a non-portable OS.

## 1. File permissions

Every OS has a different permission model. The shim normalizes it to one
three-state answer, so the core never hardcodes `chmod`, ACLs, sandbox
entitlements, or POSIX modes:

```
OraclePermissionState = .readWrite | .readOnly | .denied
permissionState(for path) -> OraclePermissionState
```

- **darwin** — App Sandbox entitlement (user-selected file read/write) + POSIX mode
  bits; `TCC` (Full Disk Access) gates the wider filesystem.
- **ios** — the app sandbox is the *only* store; there is no general filesystem
  access, so `permissionState` reflects the container, keychain, and
  `NSLocalNetworkUsageDescription` (the LAN reachability the companion needs).
- **windows** — NTFS ACLs + the packaged-app `AppContainer`; capability declarations
  (broadFileSystemAccess) map to `.readWrite`/`.denied`.
- **linux** — POSIX mode bits + sandboxing via Flatpak/bubblewrap portals; the
  portal's document store maps to `.readOnly`/`.readWrite`.

## 2. Daemon lifecycle

The daemon is the running form of the brain. **AetherOracle ships the daemon; the
native shell runs it.** The shim exposes one lifecycle surface and reports whether
the OS can host a daemon at all:

```
canRunDaemon: Bool
ensureDaemonRunning(script:ruby:projectRoot:) throws -> DaemonHandle
stop(DaemonHandle)
health(DaemonHandle) -> Bool
```

- **darwin** — spawn `standalone_daemon.rb` as a child `NSTask`, watch its stdout
  frames, restart on crash. (Current: `AetherCodex/Bridge/RubyBridge.swift`.)
- **ios** — `canRunDaemon == false`. The companion never spawns a process; it
  reaches a peer's daemon over the LAN (`AetherOracle/ruby/limen.rb` on the Mac).
- **windows** — `CreateProcess` for the daemon, or a packaged Win32 service; the
  WinUI3 shell owns the policy via this shim.
- **linux** — `fork`+`exec` child, or a `systemd` socket unit; the GTK shell owns
  the policy.

## The one rule

**The core asks for a capability; the shim decides how.** A permission check or a
daemon start never leaks OS-specific machinery into `ruby/`, `treesitter/`, or
`resources/`. That is what keeps the æther portable.
