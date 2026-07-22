import SwiftUI

// MARK: - CatalogSheet

@MainActor
struct CatalogSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var languageFilter: String = "all"
    @State private var hideBroken: Bool = true
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            // No accent wash, no aurora header, no gradient hairlines — the sheet
            // takes the system background and a real navigation title.
            Group {
                if appState.isCatalogLoading && appState.catalog.isEmpty {
                    loadingList
                } else {
                    list
                }
            }
            .navigationTitle("Add Sources")
            .searchable(
                text: $search,
                placement: .toolbar,
                prompt: "Search by name"
            )
            .searchFocused($isSearchFocused)
            // Finder's status bar: the shown / installed / total counts stay, as
            // plain secondary text instead of a gradient-separated footer.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(footerStatText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Language", selection: $languageFilter) {
                            Text("All languages").tag("all")
                            Divider()
                            ForEach(languages, id: \.self) { lang in
                                Text(lang.uppercased()).tag(lang)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Label(
                            languageFilter == "all" ? "All" : languageFilter.uppercased(),
                            systemImage: "globe"
                        )
                    }
                    .help("Filter by language")
                }

                ToolbarItem {
                    if appState.isCatalogLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await appState.reloadCatalogEntries() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh catalog")
                    }
                }

                ToolbarItem {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .frame(
            minWidth: 540, idealWidth: 720, maxWidth: 960,
            minHeight: 440, idealHeight: 600
        )
        .task {
            if appState.catalog.isEmpty { await appState.reloadCatalogEntries() }
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: Live List

    private var list: some View {
        List {
            ForEach(filtered, id: \.id) { entry in
                CatalogRow(entry: entry) {
                    Task { await appState.installFromCatalog(entry) }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: Loading (shimmer placeholders)

    private var loadingList: some View {
        List {
            ForEach(0..<6, id: \.self) { _ in
                ShimmerRow()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: Helpers

    private var footerStatText: String {
        "\(filtered.count) shown · \(installedCount) installed · \(appState.catalog.count) total"
    }

    private var languages: [String] {
        Array(Set(appState.catalog.map { $0.lang }))
            .filter { !$0.isEmpty && $0 != "all" }
            .sorted()
    }

    private var installedCount: Int {
        appState.catalog.lazy.filter { $0.isInstalled }.count
    }

    private var filtered: [HelperCatalogEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appState.catalog.filter { entry in
            if hideBroken && entry.isBroken { return false }
            if languageFilter != "all" && entry.lang != languageFilter { return false }
            if !q.isEmpty && !entry.name.lowercased().contains(q) { return false }
            return true
        }
        .sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled && !rhs.isInstalled }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }
}

// MARK: - CatalogRow

@MainActor
private struct CatalogRow: View {
    let entry: HelperCatalogEntry
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            iconZone
            infoZone
            Spacer(minLength: 8)
            actionZone
        }
        .contentShape(Rectangle())
    }

    // Plain hierarchical symbol — the gradient-filled tile with its radial
    // highlight spot is gone; orange still marks a broken source.
    private var iconZone: some View {
        Image(
            systemName: entry.isBroken
                ? "exclamationmark.triangle"
                : "puzzlepiece.extension"
        )
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(entry.isBroken ? Color.orange : Color.appAccent)
        .frame(width: 20)
    }

    // Name (+ broken marker), then ONE secondary line.
    private var infoZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if entry.isBroken {
                    Text("Broken")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("\(entry.lang.uppercased()) · \(entry.contentType)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // Right: checkmark if installed, else a stock prominent "Get".
    @ViewBuilder
    private var actionZone: some View {
        if entry.isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.medium)
                .foregroundStyle(.green)
        } else {
            Button("Get", action: onInstall)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.appAccent)
                .fixedSize()
        }
    }
}

// MARK: - ShimmerRow (loading placeholder)

@MainActor
private struct ShimmerRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .shimmer()
            .frame(height: 44)
    }
}
