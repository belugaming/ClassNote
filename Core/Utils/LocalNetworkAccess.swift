import Foundation
import Network
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// macOS only shows an app under Settings > Privacy & Security > Local Network
/// once that app has actually attempted a connection to a local-network host
/// (private IP, .local/mDNS name, or "localhost") while declaring
/// `NSLocalNetworkUsageDescription`. Declaring the Info.plist key alone does
/// nothing — this probe is what triggers the system permission prompt so the
/// toggle appears at all.
enum LocalNetworkAccess {
    enum ProbeResult {
        case notLocal          // host isn't a local-network address; nothing to probe
        case granted
        case denied
        case unreachable       // host is local but didn't respond (may still be granted)
    }

    static func isLocalNetworkHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return false }
        return isLocalNetworkHost(host: host)
    }

    static func isLocalNetworkHost(host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if h.hasPrefix("127.") { return true }
        if h.hasPrefix("10.") { return true }
        if h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("169.254.") { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// Opens a short-lived TCP connection to the given base URL's host/port so
    /// the OS surfaces the local-network permission dialog (first launch) or we
    /// can detect it was previously denied. Safe to call repeatedly.
    @discardableResult
    static func probe(baseUrlString: String, timeout: TimeInterval = 3.0) async -> ProbeResult {
        guard let url = URL(string: baseUrlString), let host = url.host, !host.isEmpty else {
            return .notLocal
        }
        guard isLocalNetworkHost(host: host) else { return .notLocal }

        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))) ?? 80
        let params = NWParameters.tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)

        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (ProbeResult) -> Void = { result in
                if !finished {
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.granted)
                case .failed(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        // Connection reached the host and was refused by the
                        // remote port — that still means local network access
                        // itself was granted.
                        finish(.granted)
                    } else if isPermissionDenied(error) {
                        finish(.denied)
                    } else {
                        finish(.unreachable)
                    }
                case .waiting(let error):
                    if isPermissionDenied(error) {
                        finish(.denied)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(.unreachable)
            }
        }
    }

    private static func isPermissionDenied(_ error: NWError) -> Bool {
        if case .dns(let dnsCode) = error, dnsCode == kDNSServiceErr_PolicyDenied {
            return true
        }
        if case .posix(let code) = error, code == .EPERM {
            return true
        }
        return false
    }

    /// Deep link straight into the relevant privacy settings pane.
    static func openSystemSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
