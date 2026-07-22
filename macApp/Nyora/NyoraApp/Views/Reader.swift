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
    var onToggleChrome: () -> Void = {}

    @EnvironmentObject var appState: AppState

    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var autoTask: Task<Void, Never>? = nil
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

                // Tap layer — centre toggles chrome, edges page (see ClickZoneLayer).
                // Disabled while zoomed so panning works.
                if zoom <= 1.001 {
                    ClickZoneLayer(
                        geo: geo,
                        onPrev: { goBack(isDouble: activeDouble) },
                        onNext: { goForward(isDouble: activeDouble) },
                        onToggle: onToggleChrome
                    )
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            // Warm the next few pages on open so the first turns are instant.
            Task.detached(priority: .background) { [appState, idx = appState.readerPageIndex] in
                await appState.prefetchReaderPages(around: idx)
            }
        }
        .onChange(of: appState.readerPageIndex) { _, newIndex in
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
        .onKeyPress(.init("a")) { appState.toggleAutoScroll(); return .handled }
        .onChange(of: appState.autoScrollOn) { _, on in on ? startAutoScroll() : stopAutoScroll() }
        .onDisappear { stopAutoScroll() }
    }

    // MARK: Auto-advance (paged)
    /// Web-style paged auto-scroll: flip forward every `autoScrollPagedDelay`
    /// seconds; goForward already rolls into the next chapter at the last page.
    private func startAutoScroll() {
        autoTask?.cancel()
        autoTask = Task {
            while !Task.isCancelled && appState.autoScrollOn {
                let delay = appState.autoScrollPagedDelay
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, appState.autoScrollOn else { return }
                if appState.readerPageIndex >= chapter.pages.count - 1, !appState.hasNextChapter {
                    appState.autoScrollOn = false
                    return
                }
                goForward(isDouble: isDouble)
            }
        }
    }
    private func stopAutoScroll() {
        autoTask?.cancel()
        autoTask = nil
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
        let step = isDouble ? 2 : 1
        let target = pageIndex - step
        if target >= 0 {
            appState.readerPageIndex = target
            Task { await appState.persistReaderPosition() }
        } else if appState.hasPrevChapter {
            // Before the first page → continue into the previous chapter.
            Task { await appState.gotoChapterRelative(-1) }
        }
    }

    private func goForward(isDouble: Bool = false) {
        let step = isDouble ? 2 : 1
        let target = pageIndex + step
        if target < chapter.pages.count {
            appState.readerPageIndex = target
            Task { await appState.persistReaderPosition() }
        } else if appState.hasNextChapter {
            // Past the last page → continue straight into the next chapter.
            Task { await appState.gotoChapterRelative(1) }
        }
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
        // Prefer the live chapter-translator image FIRST: it's re-baked onto the
        // colorized page when colorization finishes (translate + colorize compose),
        // whereas `paintedPageImage` is a one-shot mirror that wouldn't update.
        if let painted = appState.chapterTranslator.paintedImages[pageIndex] {
            return painted
        }
        if let painted = appState.paintedPageImage, appState.paintedPageURL == url {
            return painted
        }
        // Colorize-only: show the colorized page as it finishes.
        if appState.colorizeModeOn {
            return appState.colorizer.colorizedImages[pageIndex]
        }
        return nil
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
    let onToggle: () -> Void

    var body: some View {
        // Apple Books: tap the CENTRE to toggle chrome; tap the outer thirds to
        // page (direction follows readerMode.isRTL). If tap-zones are disabled,
        // a tap anywhere just toggles the chrome.
        let rtl = appState.readerMode.isRTL
        let taps = appState.readerPrefs.tapZonesEnabled
        HStack(spacing: 0) {
            Color.clear
                .frame(width: geo.size.width * 0.30)
                .contentShape(Rectangle())
                .onTapGesture { taps ? (rtl ? onNext() : onPrev()) : onToggle() }
            Color.clear
                .frame(width: geo.size.width * 0.40)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
            Color.clear
                .frame(width: geo.size.width * 0.30)
                .contentShape(Rectangle())
                .onTapGesture { taps ? (rtl ? onPrev() : onNext()) : onToggle() }
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
    var onToggleChrome: () -> Void = {}

    @EnvironmentObject var appState: AppState
    @FocusState private var focused: Bool
    @State private var visiblePage: Int = 0
    @State private var pendingPersist: Task<Void, Never>? = nil
    @State private var advancedToNext = false
    // Auto-scroll (continuous, web-style)
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollY: CGFloat = 0
    @State private var maxScrollY: CGFloat = 0
    @State private var autoTask: Task<Void, Never>? = nil

    /// Snapshot of scroll offset + travel, tracked via onScrollGeometryChange.
    private struct AutoGeo: Equatable { var y: CGFloat; var maxY: CGFloat }

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
                            // Scrolling to the end flows straight into the next chapter.
                            if appState.hasNextChapter {
                                VStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("Loading next chapter…")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 200)
                                .onAppear {
                                    guard !advancedToNext, visiblePage >= chapter.pages.count - 1 else { return }
                                    advancedToNext = true
                                    Task { await appState.gotoChapterRelative(1) }
                                }
                            }
                        }
                        .frame(width: geo.size.width)
                    }
                    .scrollIndicators(.hidden)
                    .background(Color.black)
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: AutoGeo.self) { geo in
                        AutoGeo(y: geo.contentOffset.y,
                                maxY: max(0, geo.contentSize.height - geo.containerSize.height))
                    } action: { _, g in
                        scrollY = g.y
                        maxScrollY = g.maxY
                    }
                    // Fresh scroll view per chapter — otherwise the old scroll offset
                    // carries over and the page onAppear snaps you to the middle.
                    .id(chapter.id)
                    .onChange(of: appState.autoScrollOn) { _, on in
                        on ? startAutoScroll() : stopAutoScroll()
                    }
                    .onAppear {
                        // Jump to saved position
                        if appState.readerPageIndex > 0 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(appState.readerPageIndex, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: appState.readerPageIndex) { old, new in
                        // External page-change requests (scrubber, keyboard) → INSTANT
                        // jump. No animation: an animated scrollTo flies through every
                        // intermediate page (decoding each) instead of landing directly.
                        if new != visiblePage {
                            proxy.scrollTo(new, anchor: .top)
                            visiblePage = new
                        }
                    }
                    // Tap anywhere on the strip toggles the floating chrome.
                    .simultaneousGesture(TapGesture().onEnded { onToggleChrome() })
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true; if appState.autoScrollOn { startAutoScroll() } }
        .onDisappear { stopAutoScroll() }
        // New chapter loaded — re-arm the end-of-chapter auto-continue and, if
        // auto-scroll is still on, restart the loop from the top of the new chapter.
        .onChange(of: chapter.id) { _, _ in
            advancedToNext = false
            visiblePage = 0
            if appState.autoScrollOn {
                // Wait for the fresh scroll view (.id(chapter.id)) to settle at top.
                autoTask?.cancel()
                autoTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if appState.autoScrollOn { startAutoScroll() }
                }
            }
        }
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
        .onKeyPress(.init("a")) { appState.toggleAutoScroll(); return .handled }
    }

    // MARK: Continuous auto-scroll
    /// Web-style continuous scroll: nudge the offset every frame by
    /// (px/sec ÷ 60). Reaching the bottom of the LAST page rolls into the next
    /// chapter (auto stays on and restarts); otherwise it stops at the very end.
    private func startAutoScroll() {
        autoTask?.cancel()
        autoTask = Task {
            var y = scrollY
            while !Task.isCancelled && appState.autoScrollOn {
                let step = appState.autoScrollPxPerSec / 60.0
                y += step
                scrollPosition.scrollTo(y: y)
                // End only when we're truly at the bottom AND the last page is the
                // visible one — guards against lazy rows briefly underreporting the
                // content height (which would otherwise skip a chapter).
                let atBottom = maxScrollY > 0 && y >= maxScrollY - 1
                let onLastPage = visiblePage >= chapter.pages.count - 1
                if atBottom && onLastPage {
                    if appState.hasNextChapter {
                        await appState.gotoChapterRelative(1)   // onChange(chapter.id) restarts
                    } else {
                        appState.autoScrollOn = false
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60fps
            }
        }
    }
    private func stopAutoScroll() {
        autoTask?.cancel()
        autoTask = nil
    }

    private func jumpRelative(_ delta: Int) {
        let target = appState.readerPageIndex + delta
        if target < 0 {
            // Before the first page → previous chapter.
            if appState.hasPrevChapter { Task { await appState.gotoChapterRelative(-1) } }
        } else if target >= chapter.pages.count {
            // Past the last page → next chapter.
            if appState.hasNextChapter { Task { await appState.gotoChapterRelative(1) } }
        } else {
            appState.readerPageIndex = target
        }
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
        // Prefer the live chapter-translator image FIRST: it's re-baked onto the
        // colorized page when colorization finishes (translate + colorize compose),
        // whereas `paintedPageImage` is a one-shot mirror that wouldn't update.
        if let painted = appState.chapterTranslator.paintedImages[pageIndex] {
            return painted
        }
        if let painted = appState.paintedPageImage, appState.paintedPageURL == url {
            return painted
        }
        // Colorize-only: show the colorized page as it finishes.
        if appState.colorizeModeOn {
            return appState.colorizer.colorizedImages[pageIndex]
        }
        return nil
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

// MARK: - Immersive scrubber (Apple Books style)

/// Floating bottom scrubber: a page slider with a live thumbnail preview of the
/// target page while dragging (like Apple Books). RTL-aware. Binds directly to
/// the reader's page index and works in both paged and webtoon modes.
struct ReaderScrubBar: View {
    let urls: [String]
    @Binding var page: Int
    var rtl: Bool = false

    @State private var scrubbing = false
    @State private var preview = 0            // numeric label + drag-end commit (instant)
    @State private var previewImageIndex = 0  // debounced — drives the thumbnail load
    @State private var thumb: NSImage?
    @State private var thumbTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?

    /// Tiny downsampled thumbnails, cached so re-scrubbing the same pages is free.
    nonisolated(unsafe) private static let thumbCache = NSCache<NSString, NSImage>()

    var body: some View {
        let count = max(urls.count, 1)
        let binding = Binding<Double>(
            get: { Double(scrubbing ? preview : page) },
            set: { v in
                let clamped = max(0, min(count - 1, Int(v.rounded())))
                guard clamped != preview else { return }
                preview = clamped
                // Debounce the *thumbnail* so a fast multi-page drag only decodes
                // the frame you land on — the numeric label above stays instant.
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled { previewImageIndex = clamped }
                }
            }
        )
        VStack(spacing: 10) {
            if scrubbing { thumbnailPreview(index: preview, count: count) }
            HStack(spacing: 12) {
                Text("\(preview + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 30, alignment: .trailing)
                sliderView(binding, upper: Double(count - 1))
                    .frame(maxWidth: 460)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .onChange(of: page) { _, p in if !scrubbing { preview = p } }
        .onChange(of: previewImageIndex) { _, i in loadThumb(index: i) }
        .onAppear { preview = page; previewImageIndex = page }
        .onDisappear { thumbTask?.cancel(); debounceTask?.cancel() }
        .animation(.easeOut(duration: 0.18), value: scrubbing)
    }

    @ViewBuilder
    private func sliderView(_ b: Binding<Double>, upper: Double) -> some View {
        let s = Slider(value: b, in: 0...max(upper, 0.0001), step: 1) { editing in
            if editing {
                scrubbing = true
                loadThumb(index: preview)   // warm the current frame immediately
            } else {
                scrubbing = false
                debounceTask?.cancel()
                page = preview          // commit the page only when the drag ends
            }
        }
        if rtl {
            // SwiftUI Slider can't flip natively — mirror it so drag-left advances.
            s.scaleEffect(x: -1, y: 1, anchor: .center)
        } else {
            s
        }
    }

    /// Fetch + downsample the target page OFF the main thread, cache it, and show
    /// it only if it's still the frame the user is on. Replaces the old
    /// AsyncImage(url:) which decoded the full ~2000px page lazily on main and
    /// rebuilt with a fresh identity on every drag tick.
    private func loadThumb(index: Int) {
        guard let str = urls[safe: index], let url = URL(string: str) else { thumb = nil; return }
        let key = str as NSString
        if let cached = ReaderScrubBar.thumbCache.object(forKey: key) { thumb = cached; return }
        thumbTask?.cancel()
        thumb = nil
        thumbTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            guard !Task.isCancelled else { return }
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let cg = AdjustedImageView.downsampledCGImage(from: data, maxPixel: 240) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            guard !Task.isCancelled, let img else { return }
            ReaderScrubBar.thumbCache.setObject(img, forKey: key)
            // Only publish if the user is still parked on this frame.
            if preview == index || previewImageIndex == index { thumb = img }
        }
    }

    @ViewBuilder
    private func thumbnailPreview(index: Int, count: Int) -> some View {
        VStack(spacing: 6) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 118, height: 166)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14)))
            Text("\(index + 1) / \(count)")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
