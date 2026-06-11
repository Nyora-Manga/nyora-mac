import SwiftUI
import AppKit

/// Side-by-side translation sheet.
///
/// Left column: the manga page image (so the user can match text to bubbles
/// visually). Right column: scrolling list of OCR'd text + translation pairs.
///
/// This replaces all the broken overlay/tap approaches — even with imperfect
/// bubble detection, the user gets every piece of text we could read plus its
/// translation, side-by-side with the page they're reading.
struct TranslationSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            // Left: the page itself
            ZStack {
                Color.black.opacity(0.7)
                if let img = appState.translationSheetPage?.pageImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
                } else {
                    ProgressView("Loading page…")
                        .controlSize(.large)
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 400, idealWidth: 600)

            // Right: extracted text + translation pairs
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .frame(minWidth: 360, idealWidth: 440)
            .background(.regularMaterial)
        }
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 800)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Page Translation")
                    .font(.headline)
                Text("\(appState.translateSettings.sourceLang) → \(appState.translateSettings.targetLang)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.translationSheetLoading {
                ProgressView().controlSize(.small)
            }
            Button("Done") { appState.closeTranslationSheet() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        let entries = appState.translationSheetPage?.entries ?? []
        if entries.isEmpty && appState.translationSheetLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reading the page…")
                    .font(.caption).foregroundStyle(.secondary)
                if let msg = appState.statusMessage {
                    Text(msg).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text("No text found")
                    .font(.headline)
                Text("Try a different page, or check the source language in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                        EntryRow(index: idx + 1, entry: e)
                        if idx < entries.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let entries = appState.translationSheetPage?.entries {
                Text("\(entries.count) line\(entries.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !(appState.translationSheetPage?.entries.isEmpty ?? true) {
                Button {
                    let all = (appState.translationSheetPage?.entries ?? [])
                        .map { "\($0.original)\n→ \($0.translated)" }
                        .joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(all, forType: .string)
                    appState.statusMessage = "Copied translations to clipboard"
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }
}

private struct EntryRow: View {
    @EnvironmentObject var appState: AppState
    let index: Int
    let entry: PageTranslation.Entry

    var body: some View {
        let responseScale = CGFloat(appState.readerPrefs.translationResponseScale)
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 12 * responseScale, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.original)
                    .font(.system(size: 13 * responseScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(entry.translated)
                    .font(.system(size: 15 * responseScale, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
