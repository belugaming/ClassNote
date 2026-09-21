import Foundation

/// Energy measurement for audio chunks.
///
/// Only `rms` survives: the pipeline deliberately does not pre-filter silence
/// (the STT engines need the trailing silence to decide a sentence has ended),
/// so the stateful gate this used to expose had no call sites at all.
enum VADGate {
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
