import Foundation

/// Chunk size of the local streaming model.
///
/// nemotron-3.5 is exported once per chunk size, so this picks both the model
/// file the sidecar downloads (~650 MB each) and how far behind the voice the
/// text runs. Shorter is faster on screen; longer is a little more accurate
/// (multilingual FLEURS WER: 10.4% at 80 ms, 8.8% at 1120 ms). 160 ms is the
/// default because it already puts a word up about 200 ms after it is spoken,
/// and 80 ms buys almost nothing visible for its accuracy cost.
enum LocalEngineLatency: String, CaseIterable, Identifiable {
    case ms80 = "80"
    case ms160 = "160"
    case ms320 = "320"
    case ms560 = "560"
    case ms1120 = "1120"

    var id: String { rawValue }

    var chunkMs: Int { Int(rawValue) ?? 160 }

    var title: String { "\(rawValue) ms" }

    static let `default`: LocalEngineLatency = .ms160

    static var current: LocalEngineLatency {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = LocalEngineLatency(rawValue: raw) else { return .default }
        return value
    }

    static let storageKey = "localEngineChunkMs"
}
