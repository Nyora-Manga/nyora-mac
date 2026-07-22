import SwiftUI
import AppKit

/// Local `.cbz` library pane.
///
/// Written from scratch to mirror `DownloadsView`'s proven structure — a `Group` that shows a
/// plain `EmptyStateView` or a `List`, a SINGLE toolbar item, and a `.task` loader. The previous
/// implementation scrolled the whole sidebar up whenever this pane was selected; this clean
/// rewrite behaves exactly like the other Library panes (History / Favourites / Downloads).
@MainActor
struct LocalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.localFolder.isEmpty {
                EmptyStateView(
                    icon: "folder.badge.plus",
                    title: "No Folder Selected",
                    message: "Choose a folder containing .cbz files. They will show up here as readable chapters."
                )
            } else if appState.localEntries.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "No CBZ files found",
                    message: appState.localFolder
                )
            } else {
                List {
                    ForEach(appState.localEntries) { entry in
                        LocalCbzRow(entry: entry) {
                            Task { await appState.openLocalCbz(entry) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        // A single toolbar item, like Downloads/Bookmarks. Both folder actions live in this menu
        // so the pane never adds a second focusable control that AppKit would scroll to reveal.
        .toolbar {
            Menu {
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                if !appState.localFolder.isEmpty {
                    Button {
                        Task { await appState.scanLocalFolder() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Label("Local Options", systemImage: "folder.badge.plus")
            }
        }
        .task {
            if !appState.localFolder.isEmpty && appState.localEntries.isEmpty {
                await appState.scanLocalFolder()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder that contains .cbz manga files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.localFolder = url.path
        Task { await appState.scanLocalFolder() }
    }
}

@MainActor
private struct LocalCbzRow: View {
    let entry: HelperLocalCbz
    let onOpen: () -> Void

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(Self.sizeFormatter.string(fromByteCount: entry.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
