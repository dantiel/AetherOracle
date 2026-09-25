import Foundation

/// The per-OS integration surface for the AetherOracle core.
///
/// Every platform window provides exactly two capabilities, in the language of its
/// shell: **file permissions** and **daemon lifecycle**. The core asks for a
/// capability; the shim decides how — so no OS-specific machinery leaks into the
/// portable `ruby/`, `treesitter/`, or `resources/` slices.
///
/// This is the shared protocol for the Apple platforms (darwin + ios). WinUI3 (C#)
/// and GTK (C/Rust) implement the same contract in their own languages — see the
/// per-platform README stubs.
public protocol OraclePlatform {
    /// Whether this OS can host the Ruby daemon (the calculating space in-process).
    var canRunDaemon: Bool { get }

    /// Resolve this OS's permission model for `path` to one portable three-state answer.
    func permissionState(for path: String) -> OraclePermissionState

    /// Bring the daemon to a running state; returns a handle the shell can stop/watch.
    func ensureDaemonRunning(script: String, ruby: String, projectRoot: String) throws -> OracleDaemonHandle
}

/// The portable three-state permission answer — never raw chmod/ACL/entitlement bits.
public enum OraclePermissionState {
    case readWrite
    case readOnly
    case denied
}

/// An opaque handle to a running daemon; the shell owns the policy (stop/health).
public protocol OracleDaemonHandle: AnyObject {
    func stop()
    func isHealthy() -> Bool
}
