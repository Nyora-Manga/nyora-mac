import SwiftUI

/// Bottom-of-reader HUD that visualises which step of the translation
/// pipeline is running. Each chip represents a stage:
///   Download → OCR → Translate → Refine → Done
/// Chips light up in order, the active one shows a spinner, completed
/// stages show a checkmark + elapsed seconds. Failed pipeline gets a
/// destructive red banner instead.
///
/// Visible while `appState.debugHUDEnabled == true` AND the pipeline is
/// not in `.idle`. Settings toggle controls whether the HUD ever appears.
struct TranslationDebugBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.debugHUDEnabled,
               appState.translationStage != .idle {
                content
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: appState.translationStage)
    }

    @ViewBuilder
    private var content: some View {
        if case let .failed(reason) = appState.translationStage {
            failureBanner(reason: reason)
        } else {
            stageStrip
        }
    }

    private var stageStrip: some View {
        let current = appState.translationStage
        let timings = appState.translationStageTimings
        return HStack(spacing: 6) {
            ForEach(TranslationStage.visibleStages) { stage in
                StageChip(
                    stage: stage,
                    status: status(for: stage, current: current),
                    duration: timings[stage.id]
                )
                if stage.id != TranslationStage.visibleStages.last?.id {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
    }

    private func failureBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: TranslationStage.failed("").systemImage)
                .foregroundStyle(.red)
            Text("Translation failed")
                .font(.callout.weight(.semibold))
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                appState.translationStage = .idle
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.red.opacity(0.4), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
    }

    /// Three-state status per chip:
    ///   .pending — stage hasn't been reached yet
    ///   .active  — pipeline is currently in this stage
    ///   .done    — pipeline has moved past this stage
    private func status(for stage: TranslationStage, current: TranslationStage) -> ChipStatus {
        switch current {
        case .done:                 return .done
        case .failed:               return .pending
        default:
            if stage.stepIndex < current.stepIndex { return .done }
            if stage.stepIndex == current.stepIndex { return .active }
            return .pending
        }
    }
}

private enum ChipStatus { case pending, active, done }

private struct StageChip: View {
    let stage: TranslationStage
    let status: ChipStatus
    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(stage.label)
                .font(.caption.weight(.medium))
            if let d = duration, status == .done {
                Text(formatted(d))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(textColor)
        .background(background, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: stage.systemImage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .active:
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var textColor: Color {
        switch status {
        case .pending: return .secondary
        case .active:  return .primary
        case .done:    return .primary
        }
    }

    private var background: AnyShapeStyle {
        switch status {
        case .pending: return AnyShapeStyle(Color.clear)
        case .active:  return AnyShapeStyle(Color.appAccent.opacity(0.18))
        case .done:    return AnyShapeStyle(Color.green.opacity(0.10))
        }
    }

    /// "0.8s" / "2.4s" / "12s" — compact for the bar.
    private func formatted(_ d: TimeInterval) -> String {
        if d < 1     { return String(format: "%.1fs", d) }
        if d < 10    { return String(format: "%.1fs", d) }
        return       String(format: "%.0fs", d)
    }
}
