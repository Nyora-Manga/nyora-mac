import Foundation

/// Translation pipeline configuration.
///
/// The Apple **Vision** OCR implementation that used to live here has been removed — OCR now runs
/// nyora-web's proven ONNX pipeline (bubble YOLO + manga-ocr / PaddleOCR) via `WebOcrProvider`.
/// Only the user-facing configuration types remain, so `ReaderPrefs` / Settings keep their
/// existing `OcrProvider.Tier` / `OcrProvider.PipelineConfig` API surface unchanged.
enum OcrProvider {

    /// High-level pipeline tier — a single Speed-vs-Quality preset surfaced in
    /// Settings → Translation → Speed & Quality. (With the ONNX OCR the per-tier OCR grid no
    /// longer applies; the tier is kept for settings continuity and to gate the polish step.)
    enum Tier: String, Sendable, CaseIterable, Codable, Identifiable {
        case fast
        case tuned      // Recommended
        case balanced
        case quality

        var id: String { rawValue }
        var label: String {
            switch self {
            case .fast:     return "Fast"
            case .tuned:    return "Tuned"
            case .balanced: return "Balanced"
            case .quality:  return "Quality"
            }
        }
        var subtitle: String {
            switch self {
            case .fast:     return "Fastest — minimal post-processing"
            case .tuned:    return "Recommended · best quality + speed"
            case .balanced: return "Balanced quality"
            case .quality:  return "Highest quality"
            }
        }
        var runsColumnSplit: Bool { self != .fast }
    }

    /// Pipeline knobs. The per-flag booleans aren't surfaced in Settings (the high-level `tier`
    /// is the only OCR knob the user sees) but remain so power users / future debugging can flip
    /// them in code. `applePolish` is the independent post-MT Apple Intelligence refine switch.
    struct PipelineConfig: Sendable {
        var adaptiveUpscale: Bool = true
        var medianDenoise: Bool = true
        var histogramStretch: Bool = true
        var inversionPass: Bool = true
        var rotationPass: Bool = true
        var tier: Tier = .quality
        var applePolish: Bool = true

        static let `default` = PipelineConfig()
    }
}
