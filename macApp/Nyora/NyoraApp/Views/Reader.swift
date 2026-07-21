import SwiftUI
import AppKit

// MARK: - Entry point
//
// Replaces the old ReaderPagedView / ReaderVerticalView / ReaderWebtoonView
// triad with a single clean implementation focused on desktop manga reading.
//
// Design principles:
//   - ONE GeometryReader is the source of truth for layout — everything
//     (image, overlay, click zones, controls) sizes off the same `geo.size`.
//   - Aspect-fit math is computed once and reused for the translation overlay
//     so balloons stick to bubbles pixel-for-pixel at any zoom level.
//   - Zoom/pan apply to the WHOLE composite (image + overlay) so they move
//     together. No more drifting balloons during zoom.
//   - Click-zone navigation (left 25% / right 25%) is the primary mouse UX.
//   - Keyboard: arrows, space, home/end, n/p (chapter), +/- (zoom), 0 (reset).

struct PagedReaderV2: View {
    let chapter: ChapterSummary
    let controlsVisible: Bool

    @EnvironmentObject var appState: AppState

    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @FocusState private var focused: Bool

    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 5.0

    private var isRTL: Bool { appState.readerMode.isRTL }
    private var pageIndex: Int { appState.readerPageIndex }
    private var currentURL: String? { chapter.pages[safe: pageIndex]?.url }

    private var isWindowLandscape: Bool {
        (NSApp.keyWindow?.frame.size.width ?? 1024) > (NSApp.keyWindow?.frame.size.height ?? 768)
    }

    private var isDouble: Bool {
        appState.readerPrefs.twoPageLayout && isWindowLandscape
    }

    var body: some View {
        GeometryReader { geo in
            let activeDouble = appState.readerPrefs.twoPageLayout && geo.size.width > geo.size.height
            ZStack {
                // Black backdrop fills the entire reader area
                Color.black.ignoresSafeArea()

                // The image + overlay composite (one transform space).
                // Critical: balloons live INSIDE the .scaleEffect/.offset
                // wrapping so they track the page when the user zooms/pans
                if activeDouble {
                    HStack(spacing: 0) {
                        if isRTL {
                            if pageIndex + 1 < chapter.pages.count {
                                doublePageItem(url: chapter.pages[pageIndex + 1].url, idx: pageIndex + 1, width: geo.size.width / 2, height: geo.size.height)
                            } else {
                                Spacer().frame(width: geo.size.width / 2)
                            }
                            if let url1 = currentURL {
                                doublePageItem(url: url1, idx: pageIndex, width: geo.size.width / 2, height: geo.size.height)
                            }
                        } else {
                            if let url1 = currentURL {
                                doublePageItem(url: url1, idx: pageIndex, width: geo.size.width / 2, height: geo.size.height)
                            }
                            if pageIndex + 1 < chapter.pages.count {
                                doublePageItem(url: chapter.pages[pageIndex + 1].url, idx: pageIndex + 1, width: geo.size.width / 2, height: geo.size.height)
                            } else {
                                Spacer().frame(width: geo.size.width / 2)
                            }
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(pan)
                    .gesture(zoomGesture)
                    .gesture(panGesture)
                    .onTapGesture(count: 2, perform: toggleZoom)
                } else {
                    if let url = currentURL {
                        ZStack {
                            PageImageWithOverlay(url: url, pageIndex: pageIndex, containerSize: geo.size)
                            InImageBalloonsLayerV2(containerSize: geo.size)
                                .allowsHitTesting(false)
                        }
                        .scaleEffect(zoom)
                        .offset(pan)
                        .gesture(zoomGesture)
                        .gesture(panGesture)
                        .onTapGesture(count: 2, perform: toggleZoom)
                    } else {
                        Text("No page").foregroundStyle(.white)
                    }
                }

                // Click zones — disabled when zoomed (so panning works)
                if zoom <= 1.001 {
                    ClickZoneLayer(geo: geo, onPrev: { goBack(isDouble: activeDouble) }, onNext: { goForward(isDouble: activeDouble) })
                }

                // Page counter — fades with controls
                if appState.readerPrefs.showPageNumbers, !chapter.pages.isEmpty {
                    pageCounter
                        .opacity(controlsVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            // Defer focus to the next runloop tick. Assigning focus during the
            // initial layout pass loses to the NavigationSplitView, which grabs
            // key focus for its sidebar column and swallows every reader key
            // (arrows, space, n/p, zoom) until the page is clicked. Re-asserting
            // after layout reliably lands key focus on the reader.
            DispatchQueue.main.async { focused = true }
            // Warm the next few pages on open so the first turns are instant.
            Task.detached(priority: .background) { [appState, idx = appState.readerPageIndex] in
                await appState.prefetchReaderPages(around: idx)
            }
        }
        .onChange(of: appState.readerPageIndex) { _, newIndex in
            // A page change can come from the sidebar thumbnails or the seekbar,
            // both of which steal key focus. Pull it back so keyboard paging
            // keeps working after those interactions.
            focused = true
            resetZoom()
            // Within-chapter prefetch: warm the next N pages as the user turns
            // (covers goForward/goBack/jumpTo/seekbar — all mutate readerPageIndex).
            // Background priority + fire-and-forget so it never stalls the turn.
            Task.detached(priority: .background) { [appState] in
                await appState.prefetchReaderPages(around: newIndex)
            }
        }
        // Keyboard nav — desktop-first
        .onKeyPress(.leftArrow)  { isRTL ? goForward(isDouble: isDouble) : goBack(isDouble: isDouble); return .handled }
        .onKeyPress(.rightArrow) { isRTL ? goBack(isDouble: isDouble) : goForward(isDouble: isDouble); return .handled }
        .onKeyPress(.upArrow)    { goBack(isDouble: isDouble); return .handled }
        .onKeyPress(.downArrow)  { goForward(isDouble: isDouble); return .handled }
        .onKeyPress(.pageUp)     { goBack(isDouble: isDouble); return .handled }
        .onKeyPress(.pageDown)   { goForward(isDouble: isDouble); return .handled }
        .onKeyPress(keys: [.space], phases: .down) { press in
            if press.modifiers.contains(.shift) { goBack(isDouble: isDouble) } else { goForward(isDouble: isDouble) }
            return .handled
        }
        .onKeyPress(.home) { jumpTo(0); return .handled }
        .onKeyPress(.end)  { jumpTo(chapter.pages.count - 1); return .handled }
        .onKeyPress(.init("n")) { Task { await appState.gotoChapterRelative(+1) }; return .handled }
        .onKeyPress(.init("p")) { Task { await appState.gotoChapterRelative(-1) }; return .handled }
        .onKeyPress(.init("0")) { resetZoom(); return .handled }
        .onKeyPress(.init("r")) { resetZoom(); return .handled }
        .onKeyPress(.init("+")) { setZoom(min(zoom * 1.25, maxZoom)); return .handled }
        .onKeyPress(.init("=")) { setZoom(min(zoom * 1.25, maxZoom)); return .handled }
        .onKeyPress(.init("-")) { setZoom(max(zoom / 1.25, minZoom)); return .handled }
    }

    @ViewBuilder
    private func doublePageItem(url: String, idx: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            PageImageWithOverlay(url: url, pageIndex: idx, containerSize: CGSize(width: width, height: height))
            InImageBalloonsLayerV2(containerSize: CGSize(width: width, height: height), pageIndexOverride: idx)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
    }

    // MARK: Page counter

    private var pageCounter: some View {
        VStack {
            Spacer()
            // Seekbar + page counter are sibling floating glass shapes: cluster
            // them in a single GlassEffectContainer so they blend/morph together
            // instead of double-frosting. ReaderSeekbar already carries its own
            // .glassEffect (from GlassStyles), so we add NO per-child glass here.
            GlassEffectContainer(spacing: 8) {
                ReaderSeekbar(
                    page: Binding(
                        get: { appState.readerPageIndex },
                        set: { idx in
                            appState.readerPageIndex = idx
                            Task { await appState.persistReaderPosition() }
                        }
                    ),
                    pageCount: chapter.pages.count,
                    rtl: isRTL
                )
            }
            // Lift the floating seekbar clear of the window's bottom edge so it
            // reads as a floating control, not something pinned to the frame.
            .padding(.bottom, 42)
        }
    }

    // MARK: Gestures

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(lastZoom * value, minZoom), maxZoom)
            }
            .onEnded { _ in
                lastZoom = zoom
                if zoom <= 1.0 {
                    withAnimation(.spring(response: 0.3)) { resetZoom() }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard zoom > 1.0 else { return }
                pan = CGSize(
                    width:  lastPan.width  + value.translation.width,
                    height: lastPan.height + value.translation.height
                )
            }
            .onEnded { _ in lastPan = pan }
    }

    // MARK: Navigation

    private func goBack(isDouble: Bool = false) {
        focused = true
        let step = isDouble ? 2 : 1
        let target = pageIndex - step
        guard target >= 0 else { return }
        appState.readerPageIndex = target
        Task { await appState.persistReaderPosition() }
    }

    private func goForward(isDouble: Bool = false) {
        focused = true
        let step = isDouble ? 2 : 1
        let target = pageIndex + step
        guard target < chapter.pages.count else { return }
        appState.readerPageIndex = target
        Task { await appState.persistReaderPosition() }
    }

    private func jumpTo(_ target: Int) {
        let clamped = max(0, min(chapter.pages.count - 1, target))
        appState.readerPageIndex = clamped
        Task { await appState.persistReaderPosition() }
    }

    // MARK: Zoom

    private func setZoom(_ newZoom: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = newZoom
            lastZoom = newZoom
            if newZoom <= 1.0 { pan = .zero; lastPan = .zero }
        }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3)) {
            if zoom > 1.0 { resetZoom() }
            else { zoom = 2.0; lastZoom = 2.0 }
        }
    }

    private func resetZoom() {
        zoom = 1.0
        lastZoom = 1.0
        pan = .zero
        lastPan = .zero
    }
}

// MARK: - Image + translation overlay
//
// When a painted (translation-baked-in) image exists for the current page,
// display that instead of downloading the original. The painted image already
// has bubbles white-filled + translated text drawn inside, so no overlay
// layer is needed — zoom/scroll/aspect-fit all "just work" on the new image.

private struct PageImageWithOverlay: View {
    @EnvironmentObject var appState: AppState
    let url: String
    let pageIndex: Int
    let containerSize: CGSize

    private var paintedImage: NSImage? {
        if let painted = appState.paintedPageImage, appState.paintedPageURL == url {
            return painted
        }
        return appState.chapterTranslator.paintedImages[pageIndex]
    }

    var body: some View {
        AdjustedImageView(
            url: url,
            paintedImage: paintedImage,
            adjustments: appState.effectiveColorAdjustments,
            containerSize: containerSize,
            zoomMode: appState.readerPrefs.zoomMode
        )
    }
}

// MARK: - Click zones for paging

private struct ClickZoneLayer: View {
    let geo: GeometryProxy
    @EnvironmentObject var appState: AppState
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        let isLTR = appState.readerPrefs.readerTapsLtr || !appState.rtlReading
        let inverted = appState.readerPrefs.invertNavigation
        
        // Effective LTR/RTL for the zones
        let effectiveRTL = !isLTR
        
        HStack(spacing: 0) {
            Color.clear
                .frame(width: geo.size.width * 0.25)
                .contentShape(Rectangle())
                .onTapGesture {
                    let moveNext = effectiveRTL ? !inverted : inverted
                    moveNext ? onNext() : onPrev()
                }
            Color.clear
                .frame(width: geo.size.width * 0.50)
                .allowsHitTesting(false)
            Color.clear
                .frame(width: geo.size.width * 0.25)
                .contentShape(Rectangle())
                .onTapGesture {
                    let moveNext = effectiveRTL ? inverted : !inverted
                    moveNext ? onNext() : onPrev()
                }
        }
    }
}

// MARK: - In-image balloons (cleaner version with proper aspect-fit math)

private struct InImageBalloonsLayerV2: View {
    @EnvironmentObject var appState: AppState
    let containerSize: CGSize
    var pageIndexOverride: Int? = nil


    var body: some View {
        let balloons = appState.inImageBalloons
        let imgSize = appState.inImageImageSize
        let targetIdx = pageIndexOverride ?? appState.readerPageIndex
        let curPage = appState.activeChapter?.pages[safe: targetIdx]?.url
        let matches = curPage == appState.inImageBalloonsPageURL
        let visible = !balloons.isEmpty
            && imgSize.width > 0 && imgSize.height > 0
            && matches

        ZStack(alignment: .topLeading) {
            Color.clear
            if visible {
                let responseScale = CGFloat(appState.readerPrefs.translationResponseScale)
                // SwiftUI's `.scaledToFit()` displays the image at:
                //   scale = min(W/imgW, H/imgH)
                //   displaySize = imgSize × scale
                //   offset = (containerSize − displaySize) / 2  (centered)
                // We compute the SAME values for the overlay so coords line up.
                let s = min(containerSize.width / imgSize.width,
                            containerSize.height / imgSize.height)
                let dw = imgSize.width * s
                let dh = imgSize.height * s
                let dx = (containerSize.width - dw) / 2
                let dy = (containerSize.height - dh) / 2
                ForEach(balloons) { b in
                    BalloonViewV2(text: b.translated, original: b.original)
                        .frame(maxWidth: max(80 * responseScale, b.rect.width * s * 1.15 * responseScale))
                        .position(
                            x: b.rect.midX * s + dx,
                            y: b.rect.midY * s + dy
                        )
                }
            }
        }
    }
}

private struct BalloonViewV2: View {
    @EnvironmentObject var appState: AppState
    let text: String
    let original: String

    var body: some View {
        Text(text)
            .font(.system(size: fontSize * responseScale, weight: .semibold, design: .rounded))
            .foregroundStyle(.black)
            .multilineTextAlignment(.center)
            .lineSpacing(responseScale)
            .padding(.horizontal, 9 * responseScale)
            .padding(.vertical, 5 * responseScale)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 10 * responseScale)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10 * responseScale)
                            .strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5 * responseScale)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 3 * responseScale, y: 1.5 * responseScale)
            .help(original)
    }

    private var responseScale: CGFloat {
        CGFloat(appState.readerPrefs.translationResponseScale)
    }

    private var fontSize: CGFloat {
        switch text.count {
        case 0...15:   return 15
        case 16...35:  return 12
        case 36...80:  return 10.5
        default:       return 9.5
        }
    }
}

// MARK: - Webtoon reader (continuous vertical scroll)
//
// Each page is rendered at FULL container width with proportional height.
// Translation overlays sit on top of each page using the same coordinate
// math as PagedReaderV2 — width-locked, height computed from pixel aspect.
//
// Uses SwiftUI's ScrollView + ScrollViewReader for programmatic jumps from
// the seekbar and keyboard. Tracks the most-visible page using
// scrollPosition (macOS 14+) — kept simple, no AppKit NSScrollView wrapper.

struct WebtoonReaderV2: View {
    let chapter: ChapterSummary
    let controlsVisible: Bool

    @EnvironmentObject var appState: AppState
    @FocusState private var focused: Bool
    @State private var visiblePage: Int = 0
    @State private var pendingPersist: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: appState.readerPrefs.isWebtoonGapsEnabled ? 8 : 0) {
                            ForEach(Array(chapter.pages.enumerated()), id: \.offset) { idx, page in
                                WebtoonPageV2(
                                    url: page.url,
                                    pageIndex: idx,
                                    containerWidth: geo.size.width
                                )
                                .id(idx)
                                .onAppear {
                                    if idx != visiblePage {
                                        visiblePage = idx
                                        appState.readerPageIndex = idx
                                        debouncePersist()
                                        // Symmetry with the paged reader: warm the
                                        // next few pages ahead of the scroll. The
                                        // LazyVStack already lazily loads near-visible
                                        // rows; this just gets them into URLCache a
                                        // little sooner. Background, fire-and-forget.
                                        Task.detached(priority: .background) { [appState] in
                                            await appState.prefetchReaderPages(around: idx)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: geo.size.width)
                    }
                    .scrollIndicators(.hidden)
                    .background(Color.black)
                    .onAppear {
                        // Jump to saved position
                        if appState.readerPageIndex > 0 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(appState.readerPageIndex, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: appState.readerPageIndex) { old, new in
                        // External page-change requests (seekbar, keyboard) → scroll
                        if new != visiblePage {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(new, anchor: .top)
                            }
                            visiblePage = new
                        }
                    }
                }

                if appState.readerPrefs.showPageNumbers, !chapter.pages.isEmpty {
                    ReaderSeekbar(
                        page: Binding(
                            get: { visiblePage },
                            set: { new in
                                visiblePage = new
                                appState.readerPageIndex = new
                            }
                        ),
                        pageCount: chapter.pages.count
                    )
                    .padding(.bottom, 38)
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: controlsVisible)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Defer focus past the initial layout pass so it isn't swallowed by the
        // NavigationSplitView sidebar (see PagedReaderV2 for the full rationale).
        .onAppear { DispatchQueue.main.async { focused = true } }
        // Keyboard: arrows / space scroll by page-jump
        .onKeyPress(.upArrow)   { jumpRelative(-1); return .handled }
        .onKeyPress(.downArrow) { jumpRelative(+1); return .handled }
        .onKeyPress(.pageUp)    { jumpRelative(-1); return .handled }
        .onKeyPress(.pageDown)  { jumpRelative(+1); return .handled }
        .onKeyPress(keys: [.space], phases: .down) { press in
            jumpRelative(press.modifiers.contains(.shift) ? -1 : +1)
            return .handled
        }
        .onKeyPress(.home) { jumpAbsolute(0); return .handled }
        .onKeyPress(.end)  { jumpAbsolute(chapter.pages.count - 1); return .handled }
        .onKeyPress(.init("n")) { Task { await appState.gotoChapterRelative(+1) }; return .handled }
        .onKeyPress(.init("p")) { Task { await appState.gotoChapterRelative(-1) }; return .handled }
    }

    private func jumpRelative(_ delta: Int) {
        let target = max(0, min(chapter.pages.count - 1, appState.readerPageIndex + delta))
        appState.readerPageIndex = target
    }
    private func jumpAbsolute(_ target: Int) {
        let clamped = max(0, min(chapter.pages.count - 1, target))
        appState.readerPageIndex = clamped
    }
    private func debouncePersist() {
        pendingPersist?.cancel()
        pendingPersist = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await appState.persistReaderPosition()
        }
    }
}

/// A single webtoon page — locked to containerWidth, height derived from the
/// loaded image's pixel aspect ratio. Translation balloons sit on top in the
/// same coordinate space.
private struct WebtoonPageV2: View {
    @EnvironmentObject var appState: AppState
    let url: String
    let pageIndex: Int
    let containerWidth: CGFloat

    @State private var imageAspect: CGFloat = 0.65   // typical default until image loads
    @State private var loadedPxSize: CGSize = .zero

    private var paintedImage: NSImage? {
        if let painted = appState.paintedPageImage, appState.paintedPageURL == url {
            return painted
        }
        return appState.chapterTranslator.paintedImages[pageIndex]
    }

    var body: some View {
        let zoomOutPadding = containerWidth * appState.readerPrefs.webtoonZoomOut
        let effectiveWidth = containerWidth - (zoomOutPadding * 2)
        let displayHeight = effectiveWidth / max(imageAspect, 0.01)
        ZStack(alignment: .topLeading) {
            AdjustedImageView(
                url: url,
                paintedImage: paintedImage,
                adjustments: appState.effectiveColorAdjustments,
                containerSize: CGSize(width: effectiveWidth, height: displayHeight),
                zoomMode: "fit_width",
                onImageLoaded: { size in
                    guard size.width > 0, size.height > 0 else { return }
                    let asp = size.width / size.height
                    if abs(asp - imageAspect) > 0.005 {
                        imageAspect = asp
                        loadedPxSize = size
                    }
                }
            )
            .frame(width: containerWidth, height: displayHeight)

            WebtoonPageOverlay(pageURL: url, containerSize: CGSize(width: containerWidth, height: displayHeight))
                .allowsHitTesting(false)
        }
        .frame(width: containerWidth, height: displayHeight)
    }
}

/// In-image translation balloons for a single webtoon page.
private struct WebtoonPageOverlay: View {
    @EnvironmentObject var appState: AppState
    let pageURL: String
    let containerSize: CGSize

    var body: some View {
        let balloons = appState.inImageBalloons
        let imgSize = appState.inImageImageSize
        let visible = !balloons.isEmpty
            && imgSize.width > 0 && imgSize.height > 0
            && appState.inImageBalloonsPageURL == pageURL

        ZStack(alignment: .topLeading) {
            Color.clear
            if visible {
                let responseScale = CGFloat(appState.readerPrefs.translationResponseScale)
                // Webtoon images are forced to effectiveWidth — scale = w/imgW
                let zoomOutPadding = containerSize.width * appState.readerPrefs.webtoonZoomOut
                let effectiveWidth = containerSize.width - (zoomOutPadding * 2)
                let s = effectiveWidth / imgSize.width
                ForEach(balloons) { b in
                    BalloonViewV2(text: b.translated, original: b.original)
                        .frame(maxWidth: max(80 * responseScale, b.rect.width * s * 1.15 * responseScale))
                        .position(
                            x: b.rect.midX * s + zoomOutPadding,
                            y: b.rect.midY * s
                        )
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
