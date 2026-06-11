import SwiftUI

/// Inspector-style sidebar shown in place of `SidebarView` while the user is
/// in the reader. Renders every page of the active chapter as a vertical
/// thumbnail strip — current page glows with the accent colour, click any
/// thumbnail to jump there, and the scroll position auto-follows the page
/// you're on.
///
/// Header packs a chapter selector + prev/next chapter arrows so you don't
/// have to bounce back to the details pane to switch chapters mid-binge.
struct ReaderSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var isShowingChapterMenu = false

    var body: some View {
        if let chapter = appState.activeChapter, !chapter.pages.isEmpty {
            VStack(spacing: 0) {
                header(chapter)
                Divider().opacity(0.4)
                thumbnailStrip(chapter)
            }
        } else {
            EmptyStateView(
                icon: "book.closed",
                title: "No chapter open",
                message: "Pick a chapter from a manga's details page."
            )
        }
    }

    // MARK: - Header

    private func header(_ chapter: ChapterSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.readerMangaTitle.isEmpty ? "Reader" : appState.readerMangaTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                Button {
                    Task { await appState.gotoChapterRelative(-1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(appState.readerChapterIndex <= 0)

                Button {
                    isShowingChapterMenu = true
                } label: {
                    HStack(spacing: 4) {
                        Text(chapter.title.isEmpty ? "Chapter" : chapter.title)
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingChapterMenu, arrowEdge: .bottom) {
                    chapterPicker
                }

                Button {
                    Task { await appState.gotoChapterRelative(+1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(appState.readerChapterIndex >= appState.readerChapters.count - 1)
            }

            Text("Page \(appState.readerPageIndex + 1) of \(chapter.pages.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            let done = appState.chapterTranslator.completedCount
            let total = chapter.pages.count
            if done > 0 || appState.chapterTranslator.isRunning {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .tint(.green)
                    HStack {
                        if appState.chapterTranslator.isRunning {
                            Text("Translating \(done) / \(total)")
                                .font(.caption2).foregroundStyle(.secondary)
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        } else {
                            Text("\(done) of \(total) translated")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var chapterPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(appState.readerChapters.enumerated()), id: \.element.id) { idx, ch in
                    Button {
                        isShowingChapterMenu = false
                        Task {
                            await appState.openChapter(ch, in: appState.readerChapters)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: idx == appState.readerChapterIndex ? "play.fill" : "circle")
                                .font(.caption2)
                                .foregroundStyle(idx == appState.readerChapterIndex
                                                 ? AnyShapeStyle(Color.appAccent)
                                                 : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                            Text(ch.title.isEmpty ? "Chapter \(idx + 1)" : ch.title)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(idx == appState.readerChapterIndex
                                    ? AnyShapeStyle(Color.appAccent.opacity(0.14))
                                    : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 280, height: 360)
    }

    // MARK: - Thumbnail strip

    private func thumbnailStrip(_ chapter: ChapterSummary) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(chapter.pages.enumerated()), id: \.offset) { idx, page in
                        thumbnail(pageURL: page.url, index: idx)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: appState.readerPageIndex) { _, newIdx in
                // Keep the current page visible. Use anchor .center so the
                // thumbnail sits in the middle of the strip when possible.
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
            .onAppear {
                // Jump straight to the current page when the sidebar opens —
                // no animation so we don't smear past dozens of pages.
                proxy.scrollTo(appState.readerPageIndex, anchor: .center)
            }
        }
    }

    private func thumbnail(pageURL: String, index: Int) -> some View {
        let isCurrent = index == appState.readerPageIndex
        let isTranslated = appState.chapterTranslator.paintedImages[index] != nil
        return Button {
            appState.readerPageIndex = index
            Task { await appState.persistReaderPosition() }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: pageURL)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        Rectangle()
                            .fill(.tertiary.opacity(0.3))
                            .overlay(ProgressView().controlSize(.small))
                    case .failure:
                        Rectangle()
                            .fill(.red.opacity(0.1))
                            .overlay(
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            )
                    @unknown default:
                        Rectangle().fill(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(0.7, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6),
                                in: Capsule(style: .continuous))
                    .foregroundStyle(.white)
                    .padding(6)

                // Translation status badge — top trailing corner
                if isTranslated {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.appAccent : Color.clear,
                        lineWidth: isCurrent ? 2.5 : 0
                    )
            )
            .shadow(
                color: isCurrent ? Color.appAccent.opacity(0.45) : .black.opacity(0.12),
                radius: isCurrent ? 10 : 4,
                x: 0, y: isCurrent ? 0 : 2
            )
            .scaleEffect(isCurrent ? 1.0 : 0.96)
            .animation(.easeInOut(duration: 0.18), value: isCurrent)
        }
        .buttonStyle(.plain)
    }
}
