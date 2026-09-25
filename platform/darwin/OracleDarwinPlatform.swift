import Foundation

/// macOS integration for the AetherOracle core.
///
/// Hosts the Ruby daemon as a child `NSTask` (the calculating space runs on the
/// Mac), and reads permissions through the App Sandbox entitlement + POSIX mode
/// bits. This is the reference shim; the current live wiring lives in
/// `AetherCodex/Bridge/RubyBridge.swift` and will fold into this surface.
public final class OracleDarwinPlatform: OraclePlatform {
    public init() {}

    public var canRunDaemon: Bool { true }

    public func permissionState(for path: String) -> OraclePermissionState {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { return .denied }
        if fm.isWritableFile(atPath: path) { return .readWrite }
        return fm.isReadableFile(atPath: path) ? .readOnly : .denied
    }

    public func ensureDaemonRunning(script: String, ruby: String, projectRoot: String) throws -> OracleDaemonHandle {
        // Skeleton: spawn `ruby script --project-root projectRoot` as a child
        // process, read newline-delimited frames, and hand back a handle. The live
        // logic already exists in RubyBridge.swift and is the source of truth.
        throw OraclePlatformError.notImplemented
    }
}

public enum OraclePlatformError: Error {
    case notImplemented
}
