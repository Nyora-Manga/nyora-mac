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
        ZStack {
            Color(.windowBackgroundColor)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.appAccent.opacity(0.04), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()
                    .background(Color.primary.opacity(0.07))

                if appState.isCatalogLoading && appState.catalog.isEmpty {
                    loadingList
                } else {
                    list
                }

                Divider()
                    .background(Color.primary.opacity(0.07))
                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.10), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.5)
                footer
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Add Sources")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            // Dark pill search field
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.40))
                TextField("Search by name", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .focused($isSearchFocused)
                    .onTapGesture { isSearchFocused = true }
                if !search.isEmpty {
                    Button {
                        withAnimation(.animeSpring) { search = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.30))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minWidth: 140, idealWidth: 210, maxWidth: 280)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                Color.primary.opacity(isSearchFocused ? 0.20 : 0.08),
                                lineWidth: 0.5
                            )
                    )
            )
            .animation(.glass, value: isSearchFocused)

            // Language picker as glass chip
            Menu {
                Button("All languages") { languageFilter = "all" }
                Divider()
                ForEach(languages, id: \.self) { lang in
                    Button(lang.uppercased()) { languageFilter = lang }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .medium))
                    Text(languageFilter == "all" ? "All" : languageFilter.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.55)
                }
                .foregroundStyle(.primary.opacity(0.80))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // xmark dismiss button — borderless secondary
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .contentShape(Circle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            // Layered aurora — bright accent spot topLeading + dim spot
            // bottomTrailing, single accent hue, behind the header content
            ZStack {
                RadialGradient(
                    colors: [
                        Color.appAccent.opacity(0.12),
                        Color.appAccent.opacity(0.05),
                        Color.appAccent.opacity(0.02),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 320
                )
                RadialGradient(
                    colors: [
                        Color.appAccent.opacity(0.06),
                        Color.appAccent.opacity(0.02),
                        .clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 260
                )
            }
            .allowsHitTesting(false)
        )
    }

    // MARK: Live List

    private var list: some View {
        List {
            LazyVStack(spacing: 4) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                    CatalogRow(entry: entry) {
                        Task { await appState.installFromCatalog(entry) }
                    }
                    .animeEntrance(delay: Double(min(index, 12)) * 0.04)
                }
            }
            .padding(10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: Loading (shimmer placeholders)

    private var loadingList: some View {
        List {
            LazyVStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    ShimmerRow()
                        .animeEntrance(delay: Double(index) * 0.06)
                }
            }
            .padding(10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Text(footerStatText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await appState.reloadCatalogEntries() }
            } label: {
                HStack(spacing: 5) {
                    if appState.isCatalogLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.primary.opacity(0.6))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(appState.isCatalogLoading ? "Refreshing…" : "Refresh")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.primary.opacity(appState.isCatalogLoading ? 0.40 : 0.75))
            }
            .buttonStyle(.borderless)
            .disabled(appState.isCatalogLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            iconZone
            infoZone
            Spacer(minLength: 8)
            actionZone
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isHovered
                        ? LinearGradient(
                            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.03)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        : LinearGradient(
                            colors: [Color.primary.opacity(0.03), Color.primary.opacity(0.03)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHovered
                        ? LinearGradient(
                            colors: [Color.appAccent.opacity(0.20), Color.primary.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [Color.primary.opacity(0.18), Color.primary.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                    lineWidth: 0.6
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.30, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }

    // Left icon: 36x36 RoundedRect with gradient bg
    private var iconZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    entry.isBroken
                        ? LinearGradient(
                            colors: [Color.orange.opacity(0.22), Color.orange.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color.appAccent.opacity(0.22), Color.appAccent.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                )
                // TopLeading radial highlight spot for badge depth
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    (entry.isBroken ? Color.orange : Color.appAccent).opacity(0.30),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 30
                            )
                        )
                )

            Image(
                systemName: entry.isBroken
                    ? "exclamationmark.triangle"
                    : "puzzlepiece.extension"
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(entry.isBroken ? Color.orange : Color.appAccent)
            .symbolRenderingMode(.hierarchical)
        }
        .frame(width: 36, height: 36)
    }

    // Middle: name + optional broken badge, then lang · engine · contentType
    private var infoZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if entry.isBroken {
                    Text("BROKEN")
                        .font(.system(size: 9, weight: .black))
                        .tracking(0.8)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.16))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5)
                                )
                        )
                }
            }
            Text("\(entry.lang.uppercased()) · \(entry.contentType)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // Right: green checkmark if installed, else "Get" borderedProminent small
    @ViewBuilder
    private var actionZone: some View {
        if entry.isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.medium)
                .foregroundStyle(.green)
                .shadow(color: Color.green.opacity(0.6), radius: 6)
        } else {
            InstallButton(action: onInstall)
        }
    }
}

// MARK: - InstallButton

@MainActor
private struct InstallButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Button("Get") {
                action()
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.appAccent)

            LinearGradient(
                colors: [Color.appAccent.opacity(0.15), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(Capsule())
            .allowsHitTesting(false)
        }
        .fixedSize()
        .scaleEffect(isHovered ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.70), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - ShimmerRow (loading placeholder)

@MainActor
private struct ShimmerRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .shimmer()
            .frame(height: 64)
    }
}
