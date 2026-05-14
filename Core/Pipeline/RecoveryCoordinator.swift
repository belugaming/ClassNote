import AVFoundation
import Foundation

struct RecoveryCoordinator {
    static func scanInterruptedSessions() async -> [Session] {
        do {
            let candidates = try await SessionRepository.shared.interruptedCandidates()
            var recoverable: [Session] = []
            for var session in candidates {
                guard let path = session.audioPath,
                      FileManager.default.fileExists(atPath: path) else { continue }
                if session.state != SessionState.interrupted.rawValue {
                    try await SessionRepository.shared.markInterrupted(session.id)
                    session.state = SessionState.interrupted.rawValue
                }
                recoverable.append(session)
            }
            return recoverable
        } catch {
            NSLog("[ClassNote] Recovery scan failed: \(error)")
            return []
        }
    }

    static func recover(_ session: Session) async throws {
        guard let path = session.audioPath,
              FileManager.default.fileExists(atPath: path) else {
            throw EngineError.unsupported("No recoverable audio file found.")
        }
        let durationMs = await durationMs(forAudioAt: URL(fileURLWithPath: path))
        let resolvedDuration = max(durationMs, session.durationMs)
        let endedAt = session.startedAt + resolvedDuration
        try await SessionRepository.shared.recoverInterrupted(session.id,
                                                              endedAt: endedAt,
                                                              durationMs: resolvedDuration)
    }

    static func dismiss(_ session: Session) async throws {
        try await SessionRepository.shared.setFailed(session.id)
    }

    private static func durationMs(forAudioAt url: URL) async -> Int64 {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int64(seconds * 1000)
        } catch {
            return 0
        }
    }
}
