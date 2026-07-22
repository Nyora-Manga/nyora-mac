import SwiftUI
// MARK: - DownloadsView

@MainActor
struct DownloadsView: View {
    @EnvironmentObject var appState: AppState

    @State private var showSettings = false
    @State private var maxConcurrent: Int = 3
    @State private var format: String = "AUTO"

    // Active downloads first (newest started on top), terminal ones after.
    private var sortedDownloads: [HelperDownload] {
        appState.downloads.sorted { lhs, rhs in
            if lhs.isTerminal != rhs.isTerminal { return !lhs.isTerminal }
            return lhs.startedAt > rhs.startedAt
        }
    }

    var body: some View {
        Group {
            if appState.downloads.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "No downloads yet",
                    message: "Chapters you download for offline reading will appear here."
                )
            } else {
                // The pane no longer draws its own "Downloads" caption — RootView
                // already sets .navigationTitle, so the in-pane header was a duplicate.
                List {
                    ForEach(sortedDownloads, id: \.id) { download in
                        DownloadRow(download: download)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            Button { showSettings.toggle() } label: {
                Label("Download Settings", systemImage: "gearshape")
            }
            .help("Download settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
        }
        .task {
            await appState.reloadDownloads()
            await appState.loadDownloadSettings()
            if let s = appState.downloadSettings {
                maxConcurrent = s.maxConcurrentDownloads
                format = s.format
            }
        }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Settings").font(.headline)

            Stepper(value: $maxConcurrent, in: 1...8) {
                HStack {
                    Text("Concurrent downloads")
                    Spacer()
                    Text("\(maxConcurrent)").font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Save format").font(.subheadline)
                Picker("", selection: $format) {
                    Text("Auto").tag("AUTO")
                    Text("Folder of images").tag("FOLDER")
                    Text("CBZ archive").tag("CBZ")
                    Text("ZIP archive").tag("ZIP")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()
                Button("Save") {
                    Task { await appState.updateDownloadSettings(maxConcurrent: maxConcurrent, format: format) }
                    showSettings = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 280)
    }
}

// MARK: - DownloadRow

@MainActor
private struct DownloadRow: View {
    let download: HelperDownload
    @EnvironmentObject var appState: AppState
    private var canRetry: Bool { download.status == "FAILED" || download.status == "CANCELLED" }

    /// Chapter, status and any failure detail collapsed onto ONE secondary line —
    /// the system list idiom is a title plus a single subtitle.
    private var subtitle: String {
        var parts: [String] = [download.chapterTitle, statusLabel]
        if download.failedPages > 0 { parts.append("\(download.failedPages) failed") }
        if download.isTerminal, let error = download.error, !error.isEmpty { parts.append(error) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(download.mangaTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Accent survives as a tint only.
                if !download.isTerminal {
                    ProgressView(value: download.progressFraction)
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Text("\(download.completedPages)/\(download.totalPages)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if canRetry {
                Button {
                    Task { await appState.retryDownload(download) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Retry download")
            }
        }
        .contentShape(Rectangle())
    }

    private var statusIcon: String {
        switch download.status {
        case "COMPLETED": return "checkmark.circle.fill"
        case "FAILED":    return "exclamationmark.triangle.fill"
        case "CANCELLED": return "xmark.circle"
        case "QUEUED", "PENDING": return "clock"
        default:          return "arrow.down.circle"
        }
    }

    private var statusColor: Color {
        switch download.status {
        case "COMPLETED": return .green
        case "FAILED":    return .red
        case "CANCELLED": return .secondary
        default:          return Color.appAccent
        }
    }

    private var statusLabel: String {
        download.status.capitalized
    }
}
