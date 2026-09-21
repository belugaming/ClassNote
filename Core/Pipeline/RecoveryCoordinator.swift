import AVFoundation
import Foundation

struct RecoveryCoordinator {
    static func scanInterruptedSessions() async -> [Session] {
        do {
            let candidates = try await SessionRepository.shared.interruptedCandidates()
            var recoverable: [Session] = []
            for var session in candidates {
                // Sessions whose recording is missing used to be skipped here,
                // which left them with ended_at NULL forever: rescanned at every
                // launch, never shown, never closed. They are listed too, and
                // `recover` closes them out with whatever duration is known.
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
        var resolvedDuration = session.durationMs
        if let path = session.audioPath,
           FileManager.default.fileExists(atPath: path) {
            let fileDuration = await durationMs(forAudioAt: URL(fileURLWithPath: path))
            resolvedDuration = max(fileDuration, session.durationMs)
        }
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
