import SwiftUI
/// Matches Android's reader settings sheet, all toggles wired live.
@MainActor
struct ReaderSettingsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showColorSheet = false
    @State private var showAutoScrollPopover = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                quickActions
                readMode
                layoutSection
                toolsSection
            }
            .padding(18)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560, idealHeight: 640)
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItem {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    // MARK: - sections

    private var quickActions: some View {
        VStack(spacing: 4) {
            actionRow(icon: "square.and.arrow.down", title: "Save page", subtitle: "Save current page to ~/Downloads") {
                Task { await saveCurrentPage() }
            }
            Divider()
            actionRow(
                icon: appState.currentPageBookmarked ? "bookmark.fill" : "bookmark",
                title: appState.currentPageBookmarked ? "Remove bookmark" : "Add bookmark",
                subtitle: "Bookmark the current page"
            ) {
                Task { await appState.toggleCurrentPageBookmark() }
            }
        }
        .glassCard(cornerRadius: 12)
    }

    private var readMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("READ MODE")
            HStack(spacing: 0) {
                ForEach(Array(ReaderMode.allCases.enumerated()), id: \.element.id) { idx, mode in
                    if idx > 0 { Divider().frame(height: 56) }
                    ReadModeButton(
                        mode: mode,
                        selected: appState.readerMode == mode
                    ) { appState.readerMode = mode }
                }
            }
            .glassCard(cornerRadius: 14)
            Text("The chosen mode will be remembered for this app.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("LAYOUT")
            VStack(spacing: 0) {
                toggleRow(
                    icon: "rectangle.split.2x1",
                    title: "Use two pages layout on landscape",
                    subtitle: "Pair adjacent pages side-by-side when the window is wider than tall",
                    isOn: Binding(
                        get: { appState.readerPrefs.twoPageLayout },
                        set: { appState.readerPrefs.twoPageLayout = $0 }
                    )
                )
                Divider()
                toggleRow(
                    icon: "eye.slash",
                    title: "Auto-hide controls while reading",
                    subtitle: "Fade page counter / toolbar after 2.5 s of no movement",
                    isOn: Binding(
                        get: { appState.readerPrefs.autoHideControls },
                        set: { appState.readerPrefs.autoHideControls = $0 }
                    )
                )
            }
            .glassCard(cornerRadius: 14)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("TOOLS")
            VStack(spacing: 0) {
                // ---- Automatic scroll (webtoon only)
                Button {
                    showAutoScrollPopover.toggle()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "timer").frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automatic scroll").foregroundStyle(.primary)
                            Text(autoScrollSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.readerPrefs.autoScrollSecondsPerPage > 0 {
                            Image(systemName: "checkmark").foregroundStyle(Color.appAccent)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAutoScrollPopover, arrowEdge: .leading) {
                    autoScrollPopover
                        .padding(14)
                        .frame(width: 240)
                }

                Divider()

                // ---- Color correction (opens its own sheet with preview + presets)
                Button {
                    showColorSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paintpalette").frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Color correction").foregroundStyle(.primary)
                            Text(colorCorrectionSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !appState.effectiveColorAdjustments.isNeutral {
                            Image(systemName: "checkmark").foregroundStyle(Color.appAccent)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showColorSheet) {
                    ColorCorrectionSheet().environmentObject(appState)
                }

                Divider()

                actionRow(
                    icon: appState.translateModeOn ? "character.book.closed.fill" : "character.book.closed",
                    title: appState.translateModeOn ? "Translation On (tap to disable)" : "Translate this chapter",
                    subtitle: translateSubtitle
                ) {
                    appState.translateCurrentPage()
                }
                .disabled(appState.chapterTranslator.isRunning)

                Divider()

                toggleRow(
                    icon: "hand.tap",
                    title: "Tap zones for paging",
                    subtitle: "Click left/right of the page to advance",
                    isOn: Binding(
                        get: { appState.readerPrefs.tapZonesEnabled },
                        set: { appState.readerPrefs.tapZonesEnabled = $0 }
                    )
                )
                Divider()
                toggleRow(
                    icon: "number.square",
                    title: "Show page numbers",
                    subtitle: "Display the page counter / seekbar overlay",
                    isOn: Binding(
                        get: { appState.readerPrefs.showPageNumbers },
                        set: { appState.readerPrefs.showPageNumbers = $0 }
                    )
                )
            }
            .glassCard(cornerRadius: 14)
        }
    }

    // MARK: - popovers

    private var autoScrollPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatic scroll").font(.headline)
            Text("Webtoon mode only. Smoothly scrolls one page worth every interval.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(speedOptions, id: \.0) { (label, secs) in
                    Button {
                        appState.readerPrefs.autoScrollSecondsPerPage = secs
                    } label: {
                        HStack {
                            Image(systemName: appState.readerPrefs.autoScrollSecondsPerPage == secs
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(appState.readerPrefs.autoScrollSecondsPerPage == secs
                                                 ? Color.appAccent : .secondary)
                            Text(label)
                            Spacer()
                            if secs > 0 { Text("\(Int(secs))s / page").font(.caption).foregroundStyle(.tertiary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if appState.readerMode != .webtoon {
                Text("Switch to Webtoon mode to use auto-scroll.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var speedOptions: [(String, Double)] {
        [("Off", 0), ("Slow", 8), ("Medium", 4), ("Fast", 2)]
    }

    private var translateSubtitle: String {
        if appState.chapterTranslator.isRunning { return appState.statusMessage ?? "Translating…" }
        if appState.translateModeOn {
            return "Auto-translating every page of this chapter"
        }
        return "OCR → Apple Intelligence refine → Google Translate"
    }

    private var autoScrollSubtitle: String {
        let s = appState.readerPrefs.autoScrollSecondsPerPage
        if s <= 0 { return "Webtoon mode only · off" }
        if s >= 8 { return "Slow · 8 s / page" }
        if s >= 4 { return "Medium · 4 s / page" }
        return "Fast · 2 s / page"
    }

    private var colorCorrectionSubtitle: String {
        let adj = appState.effectiveColorAdjustments
        if let preset = ColorPreset.by(id: adj.palette), preset.id != "none" {
            return "Preset · \(preset.label)"
        }
        return adj.isNeutral
            ? "Brightness / contrast / saturation / presets"
            : "Custom · tap to adjust"
    }

    // MARK: - helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.8)
            .padding(.horizontal, 4)
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button { action() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - actions

    private func saveCurrentPage() async {
        guard let chapter = appState.activeChapter,
              let page = chapter.pages[safe: appState.readerPageIndex],
              let url = URL(string: page.url)
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            let extPart = (page.url.split(separator: ".").last.map(String.init) ?? "jpg")
                .split(separator: "?").first.map(String.init) ?? "jpg"
            let safeTitle = appState.readerMangaTitle
                .replacingOccurrences(of: "/", with: "_")
                .prefix(40)
            let out = downloads.appendingPathComponent("\(safeTitle) p\(appState.readerPageIndex + 1).\(extPart)")
            try data.write(to: out)
            appState.statusMessage = "Saved page to ~/Downloads"
        } catch {
            appState.statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
private struct ReadModeButton: View {
    let mode: ReaderMode
    let selected: Bool
    let onTap: () -> Void
    var body: some View {
        Button { onTap() } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                    .font(.title3)
                    .foregroundStyle(selected ? Color.appAccent : .primary)
                Text(mode.label)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.appAccent : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, 12)
            .background(
                selected ? AnyShapeStyle(Color.appAccent.opacity(0.12)) : AnyShapeStyle(Color.clear)
            )
            // Without this, only the icon/text region is hit-testable —
            // the empty area around it doesn't accept clicks.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
