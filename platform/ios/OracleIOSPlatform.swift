import Foundation

/// iOS integration for the AetherOracle core.
///
/// iOS cannot host the Ruby daemon — no process spawning, no general filesystem.
/// `canRunDaemon == false`: the companion never runs the calculating space itself;
/// it reaches a peer's daemon over the LAN. Permissions reflect the app sandbox
/// (the only store), the keychain, and `NSLocalNetworkUsageDescription`.
public final class OracleIOSPlatform: OraclePlatform {
    public init() {}

    public var canRunDaemon: Bool { false }

    public func permissionState(for path: String) -> OraclePermissionState {
        // The sandbox container is the only writable store; everything else is
        // denied unless it is inside the container.
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return .readWrite }
        return .denied
    }

    public func ensureDaemonRunning(script: String, ruby: String, projectRoot: String) throws -> OracleDaemonHandle {
        // No daemon on iOS — the oracle is reached over the LAN.
        throw OraclePlatformError.notImplemented
    }
}
