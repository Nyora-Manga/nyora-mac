import SwiftUI
// MARK: - DownloadsView

@MainActor
struct DownloadsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

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
        ZStack {
            backdrop

            if appState.downloads.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "No downloads yet",
                    message: "Chapters you download for offline reading will appear here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Downloads")
                            .font(.system(size: 12, weight: .semibold))
                            .kerning(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)

                        // Flat rows over a faint vertical gradient section background,
                        // separated by thin hairline dividers — no boxy cards.
                        VStack(spacing: 0) {
                            ForEach(Array(sortedDownloads.enumerated()), id: \.element.id) { index, download in
                                if index > 0 {
                                    Divider()
                                        .opacity(0.4)
                                        .padding(.leading, 24)
                                }
                                DownloadRow(download: download)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(0.05),
                                            Color.primary.opacity(0.015)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download settings")
            .padding(.top, 22)
            .padding(.trailing, 22)
            .popover(isPresented: $showSettings, arrowEdge: .top) { settingsPopover }
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

    private var backdrop: some View {
        ZStack {
            Color.appBackground
            if colorScheme == .dark {
                RadialGradient(
                    colors: [Color.appAccent.opacity(0.10), Color.clear],
                    center: .topLeading, startRadius: 10, endRadius: 360
                )
                RadialGradient(
                    colors: [Color.appAccent.opacity(0.07), Color.clear],
                    center: .bottom, startRadius: 0, endRadius: 280
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - DownloadRow

@MainActor
private struct DownloadRow: View {
    let download: HelperDownload
    @EnvironmentObject var appState: AppState
    private var canRetry: Bool { download.status == "FAILED" || download.status == "CANCELLED" }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(download.mangaTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(download.chapterTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !download.isTerminal {
                    ProgressView(value: download.progressFraction)
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                } else if let error = download.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                Text("\(download.completedPages)/\(download.totalPages)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if download.failedPages > 0 {
                    Text("\(download.failedPages) failed")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.85))
                }
            }

            if canRetry {
                Button {
                    Task { await appState.retryDownload(download) }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .help("Retry download")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
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
