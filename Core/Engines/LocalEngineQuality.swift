import Foundation

/// How much of the local ASR pipeline stays resident.
///
/// `asr_server.py` has accepted `--quality` since the MLX rewrite, but nothing
/// passed it, so every machine ran `standard` — Qwen3-ASR-1.7B. Measured on an
/// 8 GB M1, that put the sidecar at 3.8 GB; with local translation's 1.1 GB
/// alongside it the machine sat on 5.3 GB of swap and live transcription became
/// unusable. The streaming model itself runs at RTF 0.17, so the bottleneck was
/// never compute.
///
/// Footprints below are measured on that machine, not estimated.
enum LocalEngineQuality: String, CaseIterable, Identifiable {
    /// Streaming model only. No second pass, so nothing corrects the live text.
    case streaming
    /// Two-pass with Qwen3-ASR-0.6B. Only ~270 MB more than `streaming` — the
    /// two-pass design was never the expensive part, the 1.7B was.
    case light
    /// Two-pass with Qwen3-ASR-1.7B. Best accuracy, needs the headroom.
    case standard

    var id: String { rawValue }

    var title: String { L10n.t("settings.engines.quality.\(rawValue)") }
    var detail: String { L10n.t("settings.engines.quality.\(rawValue)Detail") }

    /// Approximate resident size of the ASR sidecar, in MB.
    var footprintMB: Int {
        switch self {
        case .streaming: return 2130
        case .light: return 2400
        case .standard: return 3790
        }
    }

    /// Whether a second pass runs at all. Single-pass also disables file import,
    /// which has no live audio to stream and so needs the offline model.
    var hasSecondPass: Bool { self != .streaming }

    /// Default for this machine. `light` is the right call under ~12 GB: it costs
    /// barely more than single-pass and keeps the corrections.
    static var recommended: LocalEngineQuality {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gigabytes < 12 ? .light : .standard
    }

    static var current: LocalEngineQuality {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = LocalEngineQuality(rawValue: raw) else { return recommended }
        return value
    }

    static let storageKey = "localEngineQuality"
}
