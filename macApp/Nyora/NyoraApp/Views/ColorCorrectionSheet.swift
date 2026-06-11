import SwiftUI

/// A reusable colour-correction configuration: brightness/contrast/saturation/hue
/// + an optional palette name. Mapped into SwiftUI's image modifiers below.
struct ColorAdjustments: Equatable, Hashable {
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var hue: Double = 0          // degrees, mapped to .hueRotation()
    var palette: String = ""     // "" = none

    static let identity = ColorAdjustments()

    var isNeutral: Bool {
        abs(brightness) < 0.001 && abs(contrast - 1) < 0.001 &&
        abs(saturation - 1) < 0.001 && abs(hue) < 0.001 && palette.isEmpty
    }

    func merged(with palette: ColorPreset) -> ColorAdjustments {
        var copy = palette.adjustments
        copy.palette = palette.id
        return copy
    }
}

/// View modifier that applies ColorAdjustments to an Image.
extension View {
    func applyAdjustments(_ adj: ColorAdjustments) -> some View {
        self
            .brightness(adj.brightness)
            .contrast(adj.contrast)
            .saturation(adj.saturation)
            .hueRotation(.degrees(adj.hue))
    }
}

/// Named palette preset — Nyora Android's duotone/tritone/quadratone presets,
/// approximated with SwiftUI's built-in image colour modifiers. Real CIFilter
/// duotone lookup is a future iteration; for now we get close with shifts.
struct ColorPreset: Identifiable, Hashable {
    let id: String
    let group: String           // "Duotone", "Tritone", etc.
    let label: String
    let darkColor: [Double]?    // [R, G, B] in 0..255 scale
    let lightColor: [Double]?   // [R, G, B] in 0..255 scale
    let contrastOffset: Double
    let matrixArray: [Double]?  // 20 elements, with offsets in 0..255 scale
    let adjustments: ColorAdjustments

    static let allPresets: [ColorPreset] = [
        // None / Reset
        ColorPreset(id: "none", group: "Duotone", label: "None", darkColor: nil, lightColor: nil, contrastOffset: 0, matrixArray: nil, adjustments: .init()),
        
        // Duotones (1 - 5)
        ColorPreset(id: "sepia-gold", group: "Duotone", label: "Sepia Gold",
                    darkColor: [28, 22, 14], lightColor: [252, 245, 229], contrastOffset: 0.05, matrixArray: nil,
                    adjustments: .init()),
        ColorPreset(id: "slate-ocean", group: "Duotone", label: "Slate Ocean",
                    darkColor: [15, 23, 42], lightColor: [241, 245, 249], contrastOffset: -0.05, matrixArray: nil,
                    adjustments: .init()),
        ColorPreset(id: "cyberpunk-neon", group: "Duotone", label: "Cyberpunk Neon",
                    darkColor: [46, 8, 84], lightColor: [224, 247, 250], contrastOffset: 0.18, matrixArray: nil,
                    adjustments: .init()),
        ColorPreset(id: "forest-emerald", group: "Duotone", label: "Forest Emerald",
                    darkColor: [12, 35, 24], lightColor: [232, 245, 233], contrastOffset: 0.02, matrixArray: nil,
                    adjustments: .init()),
        ColorPreset(id: "warm-terracotta", group: "Duotone", label: "Warm Terracotta",
                    darkColor: [46, 26, 22], lightColor: [251, 239, 239], contrastOffset: 0.06, matrixArray: nil,
                    adjustments: .init()),
        
        // Tritones (6 - 10)
        ColorPreset(id: "vintage-classic", group: "Tritone", label: "Vintage Classic",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.0,
                    matrixArray: [
                        1.4, 0, 0, 0, 10,
                        1.1, 0, 0, 0, 25,
                        0.7, 0, 0, 0, 50,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "copper-bronze", group: "Tritone", label: "Copper Bronze",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.0,
                    matrixArray: [
                        1.3, 0, 0, 0, 30,
                        0.9, 0, 0, 0, 15,
                        0.6, 0, 0, 0, 10,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "crimson-sunset", group: "Tritone", label: "Crimson Sunset",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.05,
                    matrixArray: [
                        1.5, 0, 0, 0, 30,
                        0.8, 0, 0, 0, 10,
                        0.6, 0, 0, 0, 15,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "biolum", group: "Tritone", label: "Biolum Deep",
                    darkColor: nil, lightColor: nil, contrastOffset: -0.02,
                    matrixArray: [
                        0.6, 0, 0, 0, 10,
                        1.2, 0, 0, 0, 28,
                        1.4, 0, 0, 0, 42,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "sage", group: "Tritone", label: "Soothing Sage",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.04,
                    matrixArray: [
                        0.9, 0, 0, 0, 28,
                        1.3, 0, 0, 0, 30,
                        0.8, 0, 0, 0, 26,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        
        // Quadratones (11 - 15)
        ColorPreset(id: "retro-arcade", group: "Quadratone", label: "Retro Arcade",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.1,
                    matrixArray: [
                        1.5, 0, 0, 0, 11,
                        0.9, 0, 0, 0, 15,
                        1.3, 0, 0, 0, 25,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "cotton-candy", group: "Quadratone", label: "Cotton Candy",
                    darkColor: nil, lightColor: nil, contrastOffset: -0.05,
                    matrixArray: [
                        1.1, 0, 0, 0, 30,
                        1.2, 0, 0, 0, 27,
                        1.4, 0, 0, 0, 75,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "lavender-haze", group: "Quadratone", label: "Lavender Haze",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.02,
                    matrixArray: [
                        1.0, 0, 0, 0, 30,
                        1.1, 0, 0, 0, 27,
                        1.5, 0, 0, 0, 75,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "autumn-breeze", group: "Quadratone", label: "Autumn Breeze",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.08,
                    matrixArray: [
                        1.4, 0, 0, 0, 28,
                        1.1, 0, 0, 0, 25,
                        0.6, 0, 0, 0, 22,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "aurora", group: "Quadratone", label: "Polar Aurora",
                    darkColor: nil, lightColor: nil, contrastOffset: -0.03,
                    matrixArray: [
                        0.5, 0, 0, 0, 2,
                        1.4, 0, 0, 0, 44,
                        1.1, 0, 0, 0, 34,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        
        // Pentatones (16 - 20)
        ColorPreset(id: "synthwave-neon", group: "Pentatone", label: "Synthwave Neon",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.0,
                    matrixArray: [
                        1.6, 0, 0, 0, 26,
                        1.1, 0, 0, 0, 11,
                        1.3, 0, 0, 0, 46,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "rainbow-spectral", group: "Pentatone", label: "Rainbow Spectral",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.0,
                    matrixArray: [
                        1.5, 0, 0, 0, 36,
                        1.2, 0, 0, 0, 0,
                        0.9, 0, 0, 0, 70,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "forest-canopy", group: "Pentatone", label: "Forest Canopy",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.04,
                    matrixArray: [
                        0.7, 0, 0, 0, 6,
                        1.4, 0, 0, 0, 20,
                        0.9, 0, 0, 0, 13,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "cyber-city", group: "Pentatone", label: "Cyber City",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.12,
                    matrixArray: [
                        1.4, 0, 0, 0, 30,
                        0.9, 0, 0, 0, 17,
                        1.3, 0, 0, 0, 42,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "pastel-sweet", group: "Pentatone", label: "Pastel Sweet",
                    darkColor: nil, lightColor: nil, contrastOffset: -0.06,
                    matrixArray: [
                        1.1, 0, 0, 0, 30,
                        1.3, 0, 0, 0, 27,
                        1.4, 0, 0, 0, 75,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        
        // Hexatones (21 - 25)
        ColorPreset(id: "abyssal-trench", group: "Hexatone", label: "Abyssal Trench",
                    darkColor: nil, lightColor: nil, contrastOffset: -0.05,
                    matrixArray: [
                        0.7, 0, 0, 0, 3,
                        1.1, 0, 0, 0, 7,
                        1.5, 0, 0, 0, 24,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "thermal-fire", group: "Hexatone", label: "Thermal Fire",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.15,
                    matrixArray: [
                        1.7, 0, 0, 0, 15,
                        1.1, 0, 0, 0, 5,
                        0.6, 0, 0, 0, 5,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "sunset-horizon", group: "Hexatone", label: "Sunset Horizon",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.08,
                    matrixArray: [
                        1.5, 0, 0, 0, 30,
                        1.0, 0, 0, 0, 27,
                        0.8, 0, 0, 0, 75,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "meadow-green", group: "Hexatone", label: "Meadow Green",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.03,
                    matrixArray: [
                        0.8, 0, 0, 0, 13,
                        1.4, 0, 0, 0, 19,
                        0.9, 0, 0, 0, 13,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "vaporwave", group: "Hexatone", label: "Vaporwave Dream",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.05,
                    matrixArray: [
                        1.5, 0, 0, 0, 24,
                        0.7, 0, 0, 0, 2,
                        1.3, 0, 0, 0, 44,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        
        // Heptatones (26 - 30)
        ColorPreset(id: "nebula-glow", group: "Heptatone", label: "Nebula Glow",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.02,
                    matrixArray: [
                        1.2, 0, 0, 0, 11,
                        0.9, 0, 0, 0, 9,
                        1.5, 0, 0, 0, 26,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "glitch-cyber", group: "Heptatone", label: "Glitch Cyber",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.14,
                    matrixArray: [
                        1.6, 0, 0, 0, 3,
                        1.3, 0, 0, 0, 7,
                        1.4, 0, 0, 0, 18,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "retro-vintage", group: "Heptatone", label: "Retro Vintage",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.06,
                    matrixArray: [
                        1.4, 0, 0, 0, 28,
                        1.1, 0, 0, 0, 22,
                        0.7, 0, 0, 0, 14,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "jungle-safari", group: "Heptatone", label: "Jungle Safari",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.04,
                    matrixArray: [
                        0.7, 0, 0, 0, 2,
                        1.4, 0, 0, 0, 44,
                        0.9, 0, 0, 0, 35,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "twilight-haze", group: "Heptatone", label: "Twilight Haze",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.01,
                    matrixArray: [
                        1.1, 0, 0, 0, 23,
                        0.9, 0, 0, 0, 36,
                        1.4, 0, 0, 0, 84,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        
        // Octatones (31 - 35)
        ColorPreset(id: "acid-trippy", group: "Octatone", label: "Acid Trippy",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.15,
                    matrixArray: [
                        1.6, 0, 0, 0, 30,
                        1.3, 0, 0, 0, 5,
                        1.0, 0, 0, 0, 43,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "prism-spectral", group: "Octatone", label: "Prism Spectral",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.08,
                    matrixArray: [
                        1.4, 0, 0, 0, 9,
                        1.3, 0, 0, 0, 5,
                        1.5, 0, 0, 0, 20,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "emerald-glen", group: "Octatone", label: "Emerald Glen",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.05,
                    matrixArray: [
                        0.6, 0, 0, 0, 2,
                        1.5, 0, 0, 0, 44,
                        0.9, 0, 0, 0, 35,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "sakura-spring", group: "Octatone", label: "Sakura Spring",
                    darkColor: nil, lightColor: nil, contrastOffset: -0.04,
                    matrixArray: [
                        1.2, 0, 0, 0, 31,
                        0.9, 0, 0, 0, 22,
                        1.4, 0, 0, 0, 75,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),
        ColorPreset(id: "arctic-frost", group: "Octatone", label: "Arctic Frost",
                    darkColor: nil, lightColor: nil, contrastOffset: 0.02,
                    matrixArray: [
                        0.8, 0, 0, 0, 8,
                        1.2, 0, 0, 0, 20,
                        1.5, 0, 0, 0, 38,
                        0, 0, 0, 1, 0
                    ], adjustments: .init()),

        // Greyscale + utility
        ColorPreset(id: "grayscale", group: "Utility", label: "Grayscale",
                    darkColor: nil, lightColor: nil, contrastOffset: 0, matrixArray: nil,
                    adjustments: .init(saturation: 0)),
        ColorPreset(id: "high-contrast", group: "Utility", label: "High Contrast",
                    darkColor: nil, lightColor: nil, contrastOffset: 0, matrixArray: nil,
                    adjustments: .init(contrast: 1.6)),
        ColorPreset(id: "soft", group: "Utility", label: "Soft Tone",
                    darkColor: nil, lightColor: nil, contrastOffset: 0, matrixArray: nil,
                    adjustments: .init(brightness: 0.04, contrast: 0.9, saturation: 0.95)),
    ]

    static func by(id: String) -> ColorPreset? {
        allPresets.first { $0.id == id }
    }

    static var groupsInOrder: [String] {
        ["Duotone", "Tritone", "Quadratone", "Pentatone", "Hexatone", "Heptatone", "Octatone", "Utility"]
    }
}

/// Scope: are we editing the app-wide default, or just this one manga?
enum ColorScope: String, CaseIterable, Identifiable {
    case thisManga, allManga
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thisManga: return "This manga"
        case .allManga: return "All manga"
        }
    }
}

struct ColorCorrectionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Working copy — mutated by the sliders/preset chips and committed
    /// when the user taps Done. Cancelled if the sheet closes some other way.
    @State private var working: ColorAdjustments = .identity
    @State private var scope: ColorScope = .thisManga

    /// First-loaded current page URL for the preview thumbnails.
    private var previewURL: URL? {
        if let page = appState.activeChapter?.pages[safe: appState.readerPageIndex],
           let url = URL(string: page.url) { return url }
        // Fallback: details cover.
        return URL(string: appState.activeMangaDetails?.manga.coverUrl ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    scopePicker
                    previewPane
                    slidersSection
                    presetsSection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 600, idealHeight: 720)
        .background(.ultraThinMaterial)
        .onAppear { loadInitialAdjustments() }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3) }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
            Text("Color correction").font(.title2.bold())
            Spacer()
            Button("Reset") { working = .identity }
                .disabled(working.isNeutral)
            Button("Done") { commitAndDismiss() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: scope

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("APPLY TO")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).tracking(0.8)
            Picker("", selection: $scope) {
                ForEach(ColorScope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .tint(Color.appAccent)
            .labelsHidden()
            .onChange(of: scope) { _, _ in loadInitialAdjustments() }
            Text(scope == .thisManga
                 ? "Adjustments save only to “\(appState.readerMangaTitle.isEmpty ? "this manga" : appState.readerMangaTitle)” and override the app-wide default."
                 : "Adjustments apply to every manga unless that manga has its own override.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: preview thumbnails

    private var previewPane: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 6) {
                previewThumb(adjustments: .identity)
                Text("Original").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            VStack(spacing: 6) {
                previewThumb(adjustments: working)
                Text("Preview").font(.caption).foregroundStyle(.primary).bold()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    private func previewThumb(adjustments: ColorAdjustments) -> some View {
        Group {
            if let url = previewURL {
                AdjustedImageView(
                    url: url.absoluteString,
                    paintedImage: nil,
                    adjustments: adjustments,
                    containerSize: CGSize(width: 180, height: 252),
                    zoomMode: "fill"
                )
            } else {
                Rectangle().fill(.tertiary)
            }
        }
        .frame(width: 180, height: 252)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: sliders

    private var slidersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADJUST")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.8)
            sliderRow(icon: "sun.max", label: "Brightness",
                      value: $working.brightness, range: -0.5...0.5, neutral: 0)
            sliderRow(icon: "circle.lefthalf.filled", label: "Contrast",
                      value: $working.contrast, range: 0.5...2.0, neutral: 1)
            sliderRow(icon: "paintbrush", label: "Saturation",
                      value: $working.saturation, range: 0...2.0, neutral: 1)
            sliderRow(icon: "drop", label: "Hue",
                      value: $working.hue, range: -180...180, neutral: 0)
        }
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    private func sliderRow(
        icon: String, label: String,
        value: Binding<Double>, range: ClosedRange<Double>, neutral: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                Text(label).font(.subheadline)
                Spacer()
                Text(formatValue(value.wrappedValue, isHue: label == "Hue"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { value.wrappedValue = neutral } label: {
                    Image(systemName: "arrow.counterclockwise.circle").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reset to neutral")
            }
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in
                    // Editing sliders clears any preset selection since we've diverged.
                    if !working.palette.isEmpty { working.palette = "" }
                }
        }
    }

    private func formatValue(_ v: Double, isHue: Bool) -> String {
        if isHue { return "\(Int(v.rounded()))°" }
        return String(format: "%.2f", v)
    }

    // MARK: presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRESETS")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.8)
            ForEach(ColorPreset.groupsInOrder, id: \.self) { group in
                presetGroup(group)
            }
        }
    }

    private func presetGroup(_ groupName: String) -> some View {
        let presets = ColorPreset.allPresets.filter { $0.group == groupName }
        guard !presets.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text(groupName).font(.callout.weight(.medium))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets) { preset in
                            presetChip(preset)
                        }
                    }
                    .padding(.horizontal, 1).padding(.vertical, 2)
                }
            }
        )
    }

    private func presetChip(_ preset: ColorPreset) -> some View {
        let selected = working.palette == preset.id ||
            (preset.id == "none" && working.isNeutral)
        return Button {
            if preset.id == "none" {
                working = .identity
            } else {
                working = preset.adjustments
                working.palette = preset.id
            }
        } label: {
            Text(preset.label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    selected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.thinMaterial),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: commit

    private func loadInitialAdjustments() {
        // If editing per-manga, pull from helper (or seed from app default if missing).
        // If editing app-wide, pull from readerPrefs.
        let mangaId = appState.activeMangaDetails?.manga.id ?? appState.readerMangaId
        switch scope {
        case .thisManga where !mangaId.isEmpty:
            Task {
                if let prefs = try? await appState.helper.mangaPrefs(mangaId: mangaId), prefs.present {
                    working = ColorAdjustments(
                        brightness: prefs.brightness ?? 0,
                        contrast: prefs.contrast ?? 1,
                        saturation: prefs.saturation ?? 1,
                        hue: prefs.hue ?? 0,
                        palette: prefs.palette ?? ""
                    )
                } else {
                    working = appState.appWideColorAdjustments
                }
            }
        default:
            working = appState.appWideColorAdjustments
        }
    }

    private func commitAndDismiss() {
        switch scope {
        case .allManga:
            appState.appWideColorAdjustments = working
        case .thisManga:
            let mangaId = appState.activeMangaDetails?.manga.id ?? appState.readerMangaId
            if mangaId.isEmpty {
                appState.statusMessage = "No manga loaded — adjustments lost. Open a chapter first."
            } else {
                Task {
                    try? await appState.helper.saveMangaPrefs(
                        mangaId: mangaId,
                        readerMode: "",
                        brightness: working.brightness,
                        contrast: working.contrast,
                        saturation: working.saturation,
                        hue: working.hue,
                        palette: working.palette
                    )
                    await appState.refreshActiveMangaAdjustments()
                }
            }
        }
        dismiss()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
