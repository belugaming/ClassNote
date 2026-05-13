import Foundation

/// Simple energy-based VAD gate. Suppresses silent chunks to avoid wasting API calls.
/// Not perfect but pragmatic; replace with Silero/WhisperKit VAD in v1.1.
actor VADGate {
    private let rmsThreshold: Double
    private var lastVoicedAt: Date = .distantPast
    private let hangoverSeconds: Double = 0.8

    init(rmsThreshold: Double = 0.008) {
        self.rmsThreshold = rmsThreshold
    }

    func shouldPass(chunk: AudioChunk) -> Bool {
        let rms = Self.rms(pcm16: chunk.pcmData)
        let now = Date()
        if rms >= rmsThreshold {
            lastVoicedAt = now
            return true
        }
        if now.timeIntervalSince(lastVoicedAt) <= hangoverSeconds {
            return true
        }
        return false
    }

    static func rms(pcm16: Data) -> Double {
        guard pcm16.count >= 2 else { return 0 }
        return pcm16.withUnsafeBytes { raw -> Double in
            let count = raw.count / 2
            guard count > 0 else { return 0 }
            let ptr = raw.bindMemory(to: Int16.self)
            var sum: Double = 0
            for i in 0..<count {
                let v = Double(ptr[i]) / 32768.0
                sum += v * v
            }
            return (sum / Double(count)).squareRoot()
        }
    }
}
