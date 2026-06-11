import Foundation
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

@MainActor
final class ReaderPrefs: ObservableObject {
    private let ud = UserDefaults.standard

    init() {
        // Resolve the saved accent into the live theme holder so the entire
        // UI (Color.appAccent) shows the chosen accent from launch.
        NyoraTheme.accent = Self.resolveAccent(
            mode: accentColor,
            customHex: customAccentHex,
            wallpaperHex: wallpaperAccentHex
        )
    }

    // MARK: - General
    @Published var nsfwFilter: Bool = UserDefaults.standard.bool(forKey: Keys.nsfwFilter) {
        didSet { ud.set(nsfwFilter, forKey: Keys.nsfwFilter) }
    }
    @Published var isIncognitoModeEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.incognitoMode) {
        didSet { ud.set(isIncognitoModeEnabled, forKey: Keys.incognitoMode) }
    }
    @Published var isBiometricProtectionEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.biometricProtection) {
        didSet { ud.set(isBiometricProtectionEnabled, forKey: Keys.biometricProtection) }
    }
    @Published var appLocale: String = UserDefaults.standard.string(forKey: Keys.appLocale) ?? "auto" {
        didSet { ud.set(appLocale, forKey: Keys.appLocale) }
    }
    @Published var exitConfirm: Bool = UserDefaults.standard.bool(forKey: Keys.exitConfirm) {
        didSet { ud.set(exitConfirm, forKey: Keys.exitConfirm) }
    }
    @Published var isOnboardingComplete: Bool = UserDefaults.standard.bool(forKey: Keys.onboardingComplete) {
        didSet { ud.set(isOnboardingComplete, forKey: Keys.onboardingComplete) }
    }

    // MARK: - Appearance
    @Published var appAppearance: String = UserDefaults.standard.string(forKey: Keys.appAppearance) ?? "auto" {
        didSet { ud.set(appAppearance, forKey: Keys.appAppearance) }
    }
    @Published var amoledMode: Bool = UserDefaults.standard.bool(forKey: Keys.amoledMode) {
        didSet { ud.set(amoledMode, forKey: Keys.amoledMode) }
    }
    /// Accent mode: a preset name ("red", "orange", …, "blue", "purple",
    /// "pink"), "wallpaper", or "custom". Defaults to red.
    @Published var accentColor: String = UserDefaults.standard.string(forKey: Keys.accentColor) ?? "red" {
        didSet { ud.set(accentColor, forKey: Keys.accentColor); syncThemeAccent() }
    }
    /// Hex used when accentColor == "custom".
    @Published var customAccentHex: String = UserDefaults.standard.string(forKey: Keys.customAccentHex) ?? "#FF3B30" {
        didSet { ud.set(customAccentHex, forKey: Keys.customAccentHex); syncThemeAccent() }
    }
    /// Hex extracted from the desktop wallpaper, used when accentColor == "wallpaper".
    @Published var wallpaperAccentHex: String = UserDefaults.standard.string(forKey: Keys.wallpaperAccentHex) ?? "#FF3B30" {
        didSet { ud.set(wallpaperAccentHex, forKey: Keys.wallpaperAccentHex); syncThemeAccent() }
    }
    @Published var navLabels: Bool = (UserDefaults.standard.object(forKey: Keys.navLabels) as? Bool) ?? true {
        didSet { ud.set(navLabels, forKey: Keys.navLabels) }
    }
    @Published var dynamicShortcuts: Bool = (UserDefaults.standard.object(forKey: Keys.dynamicShortcuts) as? Bool) ?? true {
        didSet { ud.set(dynamicShortcuts, forKey: Keys.dynamicShortcuts) }
    }
    @Published var quickFilter: Bool = (UserDefaults.standard.object(forKey: Keys.quickFilter) as? Bool) ?? true {
        didSet { ud.set(quickFilter, forKey: Keys.quickFilter) }
    }
    @Published var progressIndicators: String = UserDefaults.standard.string(forKey: Keys.progressIndicators) ?? "circular" {
        didSet { ud.set(progressIndicators, forKey: Keys.progressIndicators) }
    }
    @Published var descriptionCollapse: Bool = (UserDefaults.standard.object(forKey: Keys.descriptionCollapse) as? Bool) ?? true {
        didSet { ud.set(descriptionCollapse, forKey: Keys.descriptionCollapse) }
    }
    @Published var pagesTab: Bool = (UserDefaults.standard.object(forKey: Keys.pagesTab) as? Bool) ?? true {
        didSet { ud.set(pagesTab, forKey: Keys.pagesTab) }
    }
    @Published var gridSize: Int = (UserDefaults.standard.object(forKey: Keys.gridSize) as? Int) ?? 140 {
        didSet { ud.set(gridSize, forKey: Keys.gridSize) }
    }
    @Published var showUnreadBadge: Bool = (UserDefaults.standard.object(forKey: Keys.unreadBadge) as? Bool) ?? true {
        didSet { ud.set(showUnreadBadge, forKey: Keys.unreadBadge) }
    }

    // MARK: - Reader
    @Published var defaultReaderMode: String = UserDefaults.standard.string(forKey: Keys.defaultMode) ?? "paged" {
        didSet { ud.set(defaultReaderMode, forKey: Keys.defaultMode) }
    }
    @Published var readerModeDetect: Bool = (UserDefaults.standard.object(forKey: Keys.readerModeDetect) as? Bool) ?? true {
        didSet { ud.set(readerModeDetect, forKey: Keys.readerModeDetect) }
    }
    @Published var zoomMode: String = UserDefaults.standard.string(forKey: Keys.zoomMode) ?? "fit_center" {
        didSet { ud.set(zoomMode, forKey: Keys.zoomMode) }
    }
    @Published var readerZoomButtons: Bool = UserDefaults.standard.bool(forKey: Keys.readerZoomButtons) {
        didSet { ud.set(readerZoomButtons, forKey: Keys.readerZoomButtons) }
    }
    @Published var webtoonZoom: Bool = (UserDefaults.standard.object(forKey: Keys.webtoonZoom) as? Bool) ?? true {
        didSet { ud.set(webtoonZoom, forKey: Keys.webtoonZoom) }
    }
    @Published var webtoonZoomOut: Double = (UserDefaults.standard.object(forKey: Keys.webtoonZoomOut) as? Double) ?? 0 {
        didSet { ud.set(webtoonZoomOut, forKey: Keys.webtoonZoomOut) }
    }
    @Published var isWebtoonGapsEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.webtoonGaps) {
        didSet { ud.set(isWebtoonGapsEnabled, forKey: Keys.webtoonGaps) }
    }
    @Published var webtoonPullGesture: Bool = UserDefaults.standard.bool(forKey: Keys.webtoonPullGesture) {
        didSet { ud.set(webtoonPullGesture, forKey: Keys.webtoonPullGesture) }
    }
    @Published var readerTapsLtr: Bool = UserDefaults.standard.bool(forKey: Keys.readerTapsLtr) {
        didSet { ud.set(readerTapsLtr, forKey: Keys.readerTapsLtr) }
    }
    @Published var invertNavigation: Bool = UserDefaults.standard.bool(forKey: Keys.invertNav) {
        didSet { ud.set(invertNavigation, forKey: Keys.invertNav) }
    }
    @Published var pagesNumbers: Bool = UserDefaults.standard.bool(forKey: Keys.pagesNumbers) {
        didSet { ud.set(pagesNumbers, forKey: Keys.pagesNumbers) }
    }
    @Published var prefetchNextPages: Bool = (UserDefaults.standard.object(forKey: Keys.prefetchNext) as? Bool) ?? true {
        didSet { ud.set(prefetchNextPages, forKey: Keys.prefetchNext) }
    }
    @Published var readerFullscreen: Bool = (UserDefaults.standard.object(forKey: Keys.readerFullscreen) as? Bool) ?? true {
        didSet { ud.set(readerFullscreen, forKey: Keys.readerFullscreen) }
    }
    @Published var readerScreenOn: Bool = (UserDefaults.standard.object(forKey: Keys.readerScreenOn) as? Bool) ?? true {
        didSet { ud.set(readerScreenOn, forKey: Keys.readerScreenOn) }
    }
    @Published var readerBar: Bool = (UserDefaults.standard.object(forKey: Keys.readerBar) as? Bool) ?? true {
        didSet { ud.set(readerBar, forKey: Keys.readerBar) }
    }
    @Published var readerBarTransparent: Bool = (UserDefaults.standard.object(forKey: Keys.readerBarTransparent) as? Bool) ?? true {
        didSet { ud.set(readerBarTransparent, forKey: Keys.readerBarTransparent) }
    }
    @Published var readerChapterToast: Bool = (UserDefaults.standard.object(forKey: Keys.readerChapterToast) as? Bool) ?? true {
        didSet { ud.set(readerChapterToast, forKey: Keys.readerChapterToast) }
    }
    @Published var readerBackground: String = UserDefaults.standard.string(forKey: Keys.readerBackground) ?? "auto" {
        didSet { ud.set(readerBackground, forKey: Keys.readerBackground) }
    }
    @Published var brightness: Double = (UserDefaults.standard.object(forKey: Keys.brightness) as? Double) ?? 0 {
        didSet { ud.set(brightness, forKey: Keys.brightness) }
    }
    @Published var contrast: Double = (UserDefaults.standard.object(forKey: Keys.contrast) as? Double) ?? 1 {
        didSet { ud.set(contrast, forKey: Keys.contrast) }
    }
    @Published var saturation: Double = (UserDefaults.standard.object(forKey: Keys.saturation) as? Double) ?? 1 {
        didSet { ud.set(saturation, forKey: Keys.saturation) }
    }
    @Published var hue: Double = (UserDefaults.standard.object(forKey: Keys.hue) as? Double) ?? 0 {
        didSet { ud.set(hue, forKey: Keys.hue) }
    }
    @Published var palette: String = UserDefaults.standard.string(forKey: Keys.palette) ?? "" {
        didSet { ud.set(palette, forKey: Keys.palette) }
    }
    @Published var enhancedColors: Bool = UserDefaults.standard.bool(forKey: Keys.enhancedColors) {
        didSet { ud.set(enhancedColors, forKey: Keys.enhancedColors) }
    }
    @Published var readerOptimize: Bool = UserDefaults.standard.bool(forKey: Keys.readerOptimize) {
        didSet { ud.set(readerOptimize, forKey: Keys.readerOptimize) }
    }
    @Published var readerCrop: Bool = UserDefaults.standard.bool(forKey: Keys.readerCrop) {
        didSet { ud.set(readerCrop, forKey: Keys.readerCrop) }
    }
    @Published var autoScrollSecondsPerPage: Double = (UserDefaults.standard.object(forKey: Keys.autoScroll) as? Double) ?? 0 {
        didSet { ud.set(autoScrollSecondsPerPage, forKey: Keys.autoScroll) }
    }
    @Published var twoPageLayout: Bool = (UserDefaults.standard.object(forKey: Keys.twoPage) as? Bool) ?? false {
        didSet { ud.set(twoPageLayout, forKey: Keys.twoPage) }
    }
    @Published var autoHideControls: Bool = (UserDefaults.standard.object(forKey: Keys.autoHide) as? Bool) ?? true {
        didSet { ud.set(autoHideControls, forKey: Keys.autoHide) }
    }
    @Published var tapZonesEnabled: Bool = (UserDefaults.standard.object(forKey: Keys.tapZones) as? Bool) ?? true {
        didSet { ud.set(tapZonesEnabled, forKey: Keys.tapZones) }
    }
    @Published var showPageNumbers: Bool = (UserDefaults.standard.object(forKey: Keys.showPageNumbers) as? Bool) ?? true {
        didSet { ud.set(showPageNumbers, forKey: Keys.showPageNumbers) }
    }
    @Published var readerVolumeButtons: Bool = UserDefaults.standard.bool(forKey: Keys.volumeButtons) {
        didSet { ud.set(readerVolumeButtons, forKey: Keys.volumeButtons) }
    }

    // MARK: - Library
    @Published var historyRetentionDays: Int = (UserDefaults.standard.object(forKey: Keys.retentionDays) as? Int) ?? 90 {
        didSet { ud.set(historyRetentionDays, forKey: Keys.retentionDays) }
    }
    @Published var historyGrouping: Bool = (UserDefaults.standard.object(forKey: Keys.historyGrouping) as? Bool) ?? true {
        didSet { ud.set(historyGrouping, forKey: Keys.historyGrouping) }
    }
    @Published var historySortOrder: String = UserDefaults.standard.string(forKey: Keys.historyOrder) ?? "last_read" {
        didSet { ud.set(historySortOrder, forKey: Keys.historyOrder) }
    }

    // MARK: - Network & Storage
    @Published var proxyType: String = UserDefaults.standard.string(forKey: Keys.proxyType) ?? "direct" {
        didSet { ud.set(proxyType, forKey: Keys.proxyType) }
    }
    @Published var proxyAddress: String = UserDefaults.standard.string(forKey: Keys.proxyAddress) ?? "" {
        didSet { ud.set(proxyAddress, forKey: Keys.proxyAddress) }
    }
    @Published var proxyPort: Int = (UserDefaults.standard.object(forKey: Keys.proxyPort) as? Int) ?? 0 {
        didSet { ud.set(proxyPort, forKey: Keys.proxyPort) }
    }
    @Published var dnsOverHttps: String = UserDefaults.standard.string(forKey: Keys.doh) ?? "none" {
        didSet { ud.set(dnsOverHttps, forKey: Keys.doh) }
    }
    @Published var githubMirror: String = UserDefaults.standard.string(forKey: Keys.githubMirror) ?? "KEIYOUSHI" {
        didSet { ud.set(githubMirror, forKey: Keys.githubMirror) }
    }
    @Published var imagesProxy: String = UserDefaults.standard.string(forKey: Keys.imagesProxy) ?? "none" {
        didSet { ud.set(imagesProxy, forKey: Keys.imagesProxy) }
    }
    @Published var sslBypass: Bool = UserDefaults.standard.bool(forKey: Keys.sslBypass) {
        didSet { ud.set(sslBypass, forKey: Keys.sslBypass) }
    }
    @Published var noOffline: Bool = UserDefaults.standard.bool(forKey: Keys.noOffline) {
        didSet { ud.set(noOffline, forKey: Keys.noOffline) }
    }
    @Published var isAdBlockEnabled: Bool = (UserDefaults.standard.object(forKey: Keys.adblock) as? Bool) ?? true {
        didSet { ud.set(isAdBlockEnabled, forKey: Keys.adblock) }
    }

    // MARK: - Downloads
    @Published var maxConcurrentDownloads: Int = (UserDefaults.standard.object(forKey: Keys.maxDownloads) as? Int) ?? 3 {
        didSet { ud.set(maxConcurrentDownloads, forKey: Keys.maxDownloads) }
    }
    @Published var downloadFormat: String = UserDefaults.standard.string(forKey: Keys.downloadFormat) ?? "auto" {
        didSet { ud.set(downloadFormat, forKey: Keys.downloadFormat) }
    }

    // MARK: - AI Translation (Peaked)
    @Published var useAppleOcr: Bool = UserDefaults.standard.bool(forKey: Keys.useAppleOcr) {
        didSet { ud.set(useAppleOcr, forKey: Keys.useAppleOcr) }
    }
    @Published var useMokuro: Bool = (UserDefaults.standard.object(forKey: Keys.useMokuro) as? Bool) ?? true {
        didSet { ud.set(useMokuro, forKey: Keys.useMokuro) }
    }
    @Published var aiInversionPass: Bool = (UserDefaults.standard.object(forKey: Keys.aiInversionPass) as? Bool) ?? true {
        didSet { ud.set(aiInversionPass, forKey: Keys.aiInversionPass) }
    }
    @Published var aiMedianDenoise: Bool = (UserDefaults.standard.object(forKey: Keys.aiMedianDenoise) as? Bool) ?? true {
        didSet { ud.set(aiMedianDenoise, forKey: Keys.aiMedianDenoise) }
    }
    @Published var aiHistogramStretch: Bool = (UserDefaults.standard.object(forKey: Keys.aiHistogramStretch) as? Bool) ?? true {
        didSet { ud.set(aiHistogramStretch, forKey: Keys.aiHistogramStretch) }
    }
    @Published var aiAdaptiveUpscale: Bool = (UserDefaults.standard.object(forKey: Keys.aiAdaptiveUpscale) as? Bool) ?? true {
        didSet { ud.set(aiAdaptiveUpscale, forKey: Keys.aiAdaptiveUpscale) }
    }
    @Published var aiRotationPass: Bool = (UserDefaults.standard.object(forKey: Keys.aiRotationPass) as? Bool) ?? true {
        didSet { ud.set(aiRotationPass, forKey: Keys.aiRotationPass) }
    }
    /// When ON, opening a chapter immediately starts background OCR + MT on
    /// every page in parallel so flipping forward feels instant. Off by
    /// default — chapter translation is heavy, the user opts in.
    @Published var instantTranslation: Bool = (UserDefaults.standard.object(forKey: Keys.instantTranslation) as? Bool) ?? false {
        didSet { ud.set(instantTranslation, forKey: Keys.instantTranslation) }
    }
    /// Scales translated response text in reader bubbles, painted pages, and
    /// the translation sheet. Kept as a multiplier so existing sizing logic
    /// can still fit text to each detected speech bubble.
    @Published var translationResponseScale: Double = (UserDefaults.standard.object(forKey: Keys.translationResponseScale) as? Double) ?? 1.0 {
        didSet { ud.set(translationResponseScale, forKey: Keys.translationResponseScale) }
    }
    /// High-level Speed-vs-Quality preset. See `OcrProvider.Tier` for what
    /// each setting changes (config grid size, dHash threshold, whether the
    /// Apple Intelligence polish step runs after MT).
    @Published var translationTier: OcrProvider.Tier = {
        let raw = UserDefaults.standard.string(forKey: Keys.translationTier) ?? OcrProvider.Tier.quality.rawValue
        return OcrProvider.Tier(rawValue: raw) ?? .quality
    }() {
        didSet { ud.set(translationTier.rawValue, forKey: Keys.translationTier) }
    }
    /// On/off switch for the post-MT Apple Intelligence polish step.
    /// Independent of the speed tier — any tier can run with polish on or off.
    /// Default ON because polish is the main quality differentiator.
    @Published var applePolish: Bool = (UserDefaults.standard.object(forKey: Keys.applePolish) as? Bool) ?? true {
        didSet { ud.set(applePolish, forKey: Keys.applePolish) }
    }

    // MARK: - Tracking
    @Published var isTrackerEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.trackerEnabled) {
        didSet { ud.set(isTrackerEnabled, forKey: Keys.trackerEnabled) }
    }

    // MARK: - Navigation
    /// Sidebar rows the user has chosen to show. Default includes every
    /// destination so a fresh install shows the full sidebar.
    @Published var enabledNavItems: [String] = ReaderPrefs.loadEnabledNavItems() {
        didSet { ud.set(enabledNavItems, forKey: Keys.navMain) }
    }

    /// Default order/membership of the sidebar.
    private static let defaultNavItems: [String] = [
        "history", "favourites", "local", "bookmarks", "downloads",
        "explore", "feed", "updates", "browser",
        "reader", "universalSearch", "stats", "settings",
    ]

    /// Legacy default the v1 build shipped with. If we see it stored
    /// verbatim, the user almost certainly never changed it — upgrade them
    /// to the new full sidebar instead of leaving Reader/Stats/etc hidden.
    private static let legacyV1Default: [String] = [
        "history", "favourites", "explore", "local", "updates", "settings",
    ]

    private static func loadEnabledNavItems() -> [String] {
        let ud = UserDefaults.standard
        guard var stored = ud.stringArray(forKey: Keys.navMain) else {
            return defaultNavItems
        }
        if stored == legacyV1Default {
            // Migrate silently.
            ud.set(defaultNavItems, forKey: Keys.navMain)
            return defaultNavItems
        }
        var changed = false
        // Make sure `reader` is always available — even if the user pruned
        // their sidebar, the reader pane needs a way to be reached.
        if !stored.contains("reader") {
            stored.append("reader")
            changed = true
        }
        // One-time backfill of nav destinations introduced after this user's
        // sidebar list was first saved (Downloads, Universal Search). Gated by
        // a flag so the user can still remove them afterwards.
        if !ud.bool(forKey: Keys.navBackfillV2) {
            for item in ["downloads", "universalSearch"] where !stored.contains(item) {
                stored.append(item)
                changed = true
            }
            ud.set(true, forKey: Keys.navBackfillV2)
        }
        // One-time backfill of the in-app Browser destination for existing
        // users whose sidebar list predates it. Gated by its own flag so the
        // user can still remove Browser afterwards.
        if !ud.bool(forKey: Keys.navBackfillV3) {
            for item in ["browser"] where !stored.contains(item) {
                stored.append(item)
                changed = true
            }
            ud.set(true, forKey: Keys.navBackfillV3)
        }
        if changed {
            ud.set(stored, forKey: Keys.navMain)
        }
        return stored
    }

    /// Snapshot the five OCR-pipeline toggles into the value type the
    /// `OcrProvider` actor consumes. Computed each call so the user's latest
    /// settings always win.
    var ocrPipelineConfig: OcrProvider.PipelineConfig {
        OcrProvider.PipelineConfig(
            adaptiveUpscale: aiAdaptiveUpscale,
            medianDenoise: aiMedianDenoise,
            histogramStretch: aiHistogramStretch,
            inversionPass: aiInversionPass,
            rotationPass: aiRotationPass,
            tier: translationTier,
            applePolish: applePolish
        )
    }

    // MARK: - Accent

    /// Selectable preset accents (mode name → display colour).
    static let accentPresets: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow),
        ("green", .green), ("mint", .mint), ("teal", .teal),
        ("blue", .blue), ("purple", .purple), ("pink", .pink),
    ]

    var effectiveAccentColor: Color {
        Self.resolveAccent(mode: accentColor, customHex: customAccentHex, wallpaperHex: wallpaperAccentHex)
    }

    /// Pure resolver used by both `effectiveAccentColor` and `init`.
    static func resolveAccent(mode: String, customHex: String, wallpaperHex: String) -> Color {
        switch mode {
        case "custom":    return Color(hex: customHex) ?? .red
        case "wallpaper": return Color(hex: wallpaperHex) ?? .red
        default:
            return accentPresets.first { $0.name == mode }?.color ?? .red
        }
    }

    private func syncThemeAccent() {
        NyoraTheme.accent = effectiveAccentColor
        // Nudge observers so the whole UI re-reads Color.appAccent immediately.
        objectWillChange.send()
    }

    /// Extracts a vivid dominant colour from the current desktop wallpaper and
    /// stores it as `wallpaperAccentHex`, switching the accent mode to
    /// "wallpaper". Returns false if no wallpaper colour could be read.
    @discardableResult
    func pickAccentFromWallpaper() -> Bool {
        guard let hex = Self.extractWallpaperAccentHex() else { return false }
        wallpaperAccentHex = hex
        accentColor = "wallpaper"
        return true
    }

    static func extractWallpaperAccentHex() -> String? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard
            let screen,
            let url = NSWorkspace.shared.desktopImageURL(for: screen),
            let image = NSImage(contentsOf: url),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let ci = CIImage(cgImage: cg)
        guard !ci.extent.isEmpty else { return nil }
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = ci.extent
        guard let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        let base = NSColor(srgbRed: CGFloat(px[0]) / 255,
                           green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        // Boost saturation/brightness so the accent reads as a vivid hue.
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let vivid = NSColor(hue: h,
                            saturation: max(0.55, min(1, s * 1.5)),
                            brightness: max(0.65, min(1, b * 1.15)),
                            alpha: 1)
        let r = Int((vivid.redComponent * 255).rounded())
        let g = Int((vivid.greenComponent * 255).rounded())
        let bl = Int((vivid.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, bl)
    }

    // MARK: - Helpers

    var effectiveAppearance: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var hasColorAdjustments: Bool {
        abs(brightness) > 0.001 || abs(contrast - 1) > 0.001 || abs(saturation - 1) > 0.001 || abs(hue) > 0.001
    }

    func resetColorAdjustments() {
        brightness = 0
        contrast = 1
        saturation = 1
        hue = 0
    }

    private enum Keys {
        static let nsfwFilter       = "nyora.library.nsfwFilter"
        static let incognitoMode    = "nyora.app.incognito"
        static let biometricProtection = "nyora.app.biometric"
        static let appLocale        = "nyora.app.locale"
        static let exitConfirm      = "nyora.app.exitConfirm"
        
        static let appAppearance    = "nyora.app.appearance"
        static let amoledMode       = "nyora.app.amoled"
        static let accentColor      = "nyora.app.accentColor"
        static let customAccentHex  = "nyora.app.customAccentHex"
        static let wallpaperAccentHex = "nyora.app.wallpaperAccentHex"
        static let navLabels        = "nyora.app.navLabels"
        static let dynamicShortcuts = "nyora.app.dynamicShortcuts"
        static let quickFilter      = "nyora.app.quickFilter"
        static let progressIndicators = "nyora.app.progressIndicators"
        static let descriptionCollapse = "nyora.app.descriptionCollapse"
        static let pagesTab         = "nyora.app.pagesTab"
        static let gridSize         = "nyora.library.gridSize"
        static let unreadBadge      = "nyora.library.unreadBadge"
        
        static let defaultMode      = "nyora.reader.defaultMode"
        static let readerModeDetect = "nyora.reader.modeDetect"
        static let zoomMode         = "nyora.reader.zoomMode"
        static let readerZoomButtons = "nyora.reader.zoomButtons"
        static let webtoonZoom      = "nyora.reader.webtoonZoom"
        static let webtoonZoomOut   = "nyora.reader.webtoonZoomOut"
        static let webtoonGaps      = "nyora.reader.webtoonGaps"
        static let webtoonPullGesture = "nyora.reader.pullGesture"
        static let readerTapsLtr    = "nyora.reader.tapsLtr"
        static let invertNav        = "nyora.reader.invertNav"
        static let pagesNumbers     = "nyora.reader.pagesNumbers"
        static let prefetchNext     = "nyora.reader.prefetchNext"
        static let readerFullscreen = "nyora.reader.fullscreen"
        static let readerScreenOn   = "nyora.reader.screenOn"
        static let readerBar        = "nyora.reader.bar"
        static let readerBarTransparent = "nyora.reader.barTransparent"
        static let readerChapterToast = "nyora.reader.chapterToast"
        static let readerBackground = "nyora.reader.background"
        static let brightness       = "nyora.reader.brightness"
        static let contrast         = "nyora.reader.contrast"
        static let saturation       = "nyora.reader.saturation"
        static let hue              = "nyora.reader.hue"
        static let palette          = "nyora.reader.palette"
        static let enhancedColors   = "nyora.reader.enhancedColors"
        static let readerOptimize   = "nyora.reader.optimize"
        static let readerCrop       = "nyora.reader.crop"
        static let autoScroll       = "nyora.reader.autoScroll"
        static let twoPage          = "nyora.reader.twoPage"
        static let autoHide         = "nyora.reader.autoHide"
        static let tapZones         = "nyora.reader.tapZones"
        static let showPageNumbers  = "nyora.reader.showPageNumbers"
        static let volumeButtons    = "nyora.reader.volumeButtons"
        
        static let retentionDays    = "nyora.history.retentionDays"
        static let historyGrouping  = "nyora.history.grouping"
        static let historyOrder     = "nyora.history.order"
        
        static let proxyType        = "nyora.network.proxyType"
        static let proxyAddress     = "nyora.network.proxyAddress"
        static let proxyPort        = "nyora.network.proxyPort"
        static let doh              = "nyora.network.doh"
        static let githubMirror     = "nyora.network.githubMirror"
        static let imagesProxy      = "nyora.network.imagesProxy"
        static let sslBypass        = "nyora.network.sslBypass"
        static let noOffline        = "nyora.network.noOffline"
        static let adblock          = "nyora.network.adblock"
        
        static let maxDownloads     = "nyora.downloads.maxConcurrent"
        static let downloadFormat   = "nyora.downloads.format"
        
        static let useAppleOcr      = "nyora.ai.translate.useAppleOcr"
        static let useMokuro        = "nyora.ai.translate.useMokuro"
        static let aiInversionPass  = "nyora.ai.translate.inversion"
        static let aiMedianDenoise  = "nyora.ai.translate.denoise"
        static let aiHistogramStretch = "nyora.ai.translate.stretch"
        static let aiAdaptiveUpscale = "nyora.ai.translate.upscale"
        static let aiRotationPass   = "nyora.ai.translate.rotation"
        static let instantTranslation = "nyora.ai.translate.instant"
        static let translationResponseScale = "nyora.ai.translate.responseScale"
        static let translationTier  = "nyora.ai.translate.tier"
        static let applePolish      = "nyora.ai.translate.applePolish"

        static let trackerEnabled   = "nyora.tracker.enabled"
        static let onboardingComplete = "nyora.onboarding.complete"
        static let navMain          = "nyora.nav.main"
        static let navBackfillV2     = "nyora.nav.backfill.v2"
        static let navBackfillV3     = "nyora.nav.backfill.v3"
    }
}
