import SwiftUI

// MARK: - App Accent Theme
//
// The whole UI draws its accent from `Color.appAccent` rather than the static system
// `Color.accentColor`, so the user-chosen accent (preset / wallpaper /
// custom) actually re-colours every gradient and control. `NyoraTheme.accent`
// is the live value; ReaderPrefs updates it whenever the accent setting
// changes, and views re-render through the normal observation chain.
enum NyoraTheme {
    /// Mutated only on the main actor (from ReaderPrefs); reads are cheap.
    nonisolated(unsafe) static var accent: Color = .red
}

extension Color {
    /// The user-selected app accent. Use this everywhere instead of
    /// `Color.accentColor` so the accent setting drives the entire UI.
    static var appAccent: Color { NyoraTheme.accent }

    /// Hex initializer — supports "#RRGGBB" / "RRGGBB" (and 8-digit alpha).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
            a = 1
        } else {
            r = Double((v & 0xFF000000) >> 24) / 255
            g = Double((v & 0x00FF0000) >> 16) / 255
            b = Double((v & 0x0000FF00) >> 8) / 255
            a = Double(v & 0x000000FF) / 255
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// "#RRGGBB" hex string for this colour (best-effort, sRGB).
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Adaptive Color Tokens
extension Color {
    /// Main app/view background — adapts to dark (near-black) and light mode automatically.
    static var appBackground: Color { Color(.windowBackgroundColor) }

    /// Elevated card surface — slightly lighter than appBackground.
    static var cardSurface: Color { Color(.controlBackgroundColor) }

    /// Separator/border color — adapts to dark/light.
    static var adaptiveSeparator: Color { Color(.separatorColor) }
}

@MainActor
struct AdaptiveBackdropModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let primary: Color
    let secondary: Color

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Color.appBackground
                if colorScheme == .dark {
                    RadialGradient(colors: [primary.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
                    RadialGradient(colors: [secondary.opacity(0.12), .clear], center: .bottomLeading, startRadius: 0, endRadius: 360)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: colorScheme)
            .ignoresSafeArea()
        }
    }
}

extension View {
    func adaptiveBackdrop(primary: Color, secondary: Color) -> some View {
        modifier(AdaptiveBackdropModifier(primary: primary, secondary: secondary))
    }
}

// MARK: - Design Tokens

/// Common animation curves and spring presets for the Awwwards-level anime system.
extension Animation {
    /// Fast glass transitions — hover feedback, opacity flips.
    static var glass: Animation { .smooth(duration: 0.18) }

    /// Spring hover / focus transitions — scale, translate, glow.
    static var animeSpring: Animation {
        .spring(response: 0.38, dampingFraction: 0.65)
    }

    /// Entrance spring — slower, more dramatic.
    static var animeEntrance: Animation {
        .spring(response: 0.55, dampingFraction: 0.75)
    }

    /// Snappy hover spring — tighter than animeSpring for immediate feedback.
    static var hoverSpring: Animation {
        .spring(response: 0.32, dampingFraction: 0.68)
    }

    /// Selection spring — crisp state transitions.
    static var selectSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.72)
    }

    /// Page/section cross-fade — clean lateral transitions.
    static var pageTransition: Animation {
        .easeInOut(duration: 0.22)
    }
}

// MARK: - Gradient Convenience Helpers

extension View {
    /// Convenience single-hue linear gradient for badge/button accent fills.
    func accentGradient(_ accent: Color = .appAccent) -> LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.95), accent.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Overlays a top-edge white glow highlight clipped to a rounded rect.
    func innerHighlight(cornerRadius: CGFloat) -> some View {
        overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .frame(height: 40)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Modern Gradient Primitives (2024 aesthetic)

/// AURORA FILL — the core modern surface look. Layers 2-3 radial accent spots
/// over a subtle base wash to create organic depth instead of a flat diagonal
/// band. All hue derives from the accent at varying opacity (single-hue).
@MainActor
struct AuroraFill: View {
    var accent: Color = .appAccent
    var cornerRadius: CGFloat = 16
    var body: some View {
        ZStack {
            // base wash
            LinearGradient(colors: [accent.opacity(0.10), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)
            // bright corner spot
            RadialGradient(colors: [accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            // secondary dim spot
            RadialGradient(colors: [accent.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 300)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// ANGULAR CONIC BORDER — a conic sweep of the accent at varying opacity, giving
/// a modern rotating-light edge. Use on hero/premium surfaces and cards.
@MainActor
struct ConicBorderModifier: ViewModifier {
    let cornerRadius: CGFloat
    let accent: Color
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [accent.opacity(0.40), accent.opacity(0.08), accent.opacity(0.30), accent.opacity(0.06), accent.opacity(0.40)]),
                        center: .center
                    ),
                    lineWidth: 0.9
                )
        )
    }
}

extension View {
    func conicBorder(cornerRadius: CGFloat = 16, accent: Color = .appAccent) -> some View {
        modifier(ConicBorderModifier(cornerRadius: cornerRadius, accent: accent))
    }
}

/// MESH HERO BACKGROUND — a soft accent mesh for hero/premium surfaces.
/// `MeshGradient` is macOS 15+, so it is gated and falls back to `AuroraFill`
/// on macOS 14.
@MainActor
struct ModernHeroBackground: View {
    var accent: Color = .appAccent
    var cornerRadius: CGFloat = 24
    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                MeshGradient(width: 3, height: 3, points: [
                    [0,0],[0.5,0],[1,0],
                    [0,0.5],[0.5,0.5],[1,0.5],
                    [0,1],[0.5,1],[1,1]
                ], colors: [
                    accent.opacity(0.28), accent.opacity(0.14), accent.opacity(0.22),
                    accent.opacity(0.12), accent.opacity(0.06), accent.opacity(0.16),
                    accent.opacity(0.20), accent.opacity(0.08), accent.opacity(0.24)
                ])
            } else {
                AuroraFill(accent: accent, cornerRadius: cornerRadius)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// Convenience modern card: AuroraFill background + conic border + the
    /// standard 2-layer shadow (near black, far accent).
    func auroraCard(cornerRadius: CGFloat = 16, accent: Color = .appAccent) -> some View {
        self
            .background(AuroraFill(accent: accent, cornerRadius: cornerRadius))
            .conicBorder(cornerRadius: cornerRadius, accent: accent)
            // Near shadow
            .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 5)
            // Far ambient accent shadow
            .shadow(color: accent.opacity(0.12), radius: 20, x: 0, y: 8)
    }
}

// MARK: - View Extension Entry-Points

extension View {
    // ── Existing surfaces ───────────────────────────────────────────────────

    /// Main panel surface — big cards, sheet bodies, content frames.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Floating overlay surface — toolbars, page counters, status banners.
    func glassOverlay(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassOverlayModifier(cornerRadius: cornerRadius))
    }

    /// Subtle hover / selected affordance — list rows, sidebar items.
    func glassRow(selected: Bool = false, isHovered: Bool = false, cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassRowModifier(selected: selected, isHovered: isHovered, cornerRadius: cornerRadius))
    }

    /// Drop-in replacement for a "chip" / tag pill.
    func glassChip(cornerRadius: CGFloat = 999) -> some View {
        modifier(GlassChipModifier(cornerRadius: cornerRadius))
    }

    // ── Anime surfaces ───────────────────────────────────────────────────────

    /// Cover-card treatment — inner highlight, drop shadow stack, clip.
    func animeCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(AnimeCardModifier(cornerRadius: cornerRadius))
    }

    /// Ambient glow + resting soft shadow combo.
    /// - Parameters:
    ///   - color: The glow accent colour.
    ///   - isActive: Whether the glow is lit (e.g. isHovered).
    func glowShadow(color: Color, isActive: Bool) -> some View {
        modifier(GlowShadowModifier(color: color, isActive: isActive))
    }

    /// Animated shimmer overlay — use on placeholder shapes while loading.
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }

    /// Staggered easeOut entrance: fade + slide-up. Faster than spring for
    /// scroll-list items where snappy arrival matters more than bounciness.
    /// - Parameter delay: Extra delay in seconds (use `index * 0.06` for stagger).
    func animeEntrance(delay: Double = 0) -> some View {
        modifier(AnimeEntranceModifier(delay: delay))
    }

    // ── New surfaces ─────────────────────────────────────────────────────────

    /// Cover-image card treatment.
    ///
    /// Note: callers are responsible for enforcing a 2:3 aspect ratio on the
    /// content frame (e.g. `.aspectRatio(2/3, contentMode: .fit)`); this
    /// modifier clips, highlights, and shadows but does not impose dimensions.
    func coverCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(CoverCardModifier(cornerRadius: cornerRadius))
    }

    /// Small filled capsule — count badges, status indicators.
    /// - Parameter color: Fill accent colour.
    func mangaBadge(color: Color) -> some View {
        modifier(MangaBadgeModifier(color: color))
    }

    /// Section container glass surface — slightly stronger fill than glassCard,
    /// intended for grouping rows or grids within a larger layout.
    func glassSection(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSectionModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - GlassCardModifier

/// MODERN aurora card surface:
/// • Layered-radial AuroraFill background (single-hue accent depth)
/// • Conic AngularGradient border (rotating-light edge)
/// • Inner top highlight (accent 0.14 → clear) height 40
/// • 2-layer shadow: near black + far accent
@MainActor
struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AuroraFill(accent: .appAccent, cornerRadius: cornerRadius))
            .conicBorder(cornerRadius: cornerRadius, accent: .appAccent)
            // Inner top-edge accent highlight
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.14), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: 40)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            }
            // Near shadow
            .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 5)
            // Far ambient accent shadow
            .shadow(color: Color.appAccent.opacity(0.12), radius: 20, x: 0, y: 8)
    }
}

// MARK: - GlassRowModifier

/// AWWWARDS-level row surface:
/// • Selected: appAccent gradient leading→trailing (0.22 → 0.08) + appAccent shadow
/// • Hover: primary gradient (0.08 → 0.03)
/// • Resting: primary gradient (0.05 → 0.02)
/// • Gradient border always present
@MainActor
struct GlassRowModifier: ViewModifier {
    let selected: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        selected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color.appAccent.opacity(0.22),
                                        Color.appAccent.opacity(0.08),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                              )
                            : isHovered
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(0.08),
                                            Color.primary.opacity(0.03),
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                  )
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(0.05),
                                            Color.primary.opacity(0.02),
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                  )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(selected ? 0.14 : (isHovered ? 0.10 : 0.06)),
                                Color.primary.opacity(selected ? 0.05 : (isHovered ? 0.04 : 0.02)),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
            // Accent shadow when selected
            .shadow(
                color: selected ? Color.appAccent.opacity(0.28) : .clear,
                radius: selected ? 10 : 0,
                x: 0,
                y: selected ? 4 : 0
            )
    }
}

// MARK: - GlassChipModifier

/// AWWWARDS-level chip/tag pill:
/// • 2-stop gradient fill (0.10 → 0.05)
/// • Gradient border top→bottom
@MainActor
struct GlassChipModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.10),
                                Color.primary.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.18),
                                Color.primary.opacity(0.06),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
            )
    }
}

// MARK: - GlassOverlayModifier

@MainActor
struct GlassOverlayModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.48))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - AnimeCardModifier

/// AWWWARDS-level cover-card surface treatment:
/// • Continuous clip shape
/// • Richer inner top highlight (white 0.14 → clear, top 35%)
/// • Gradient clip border: white 0.20 → white 0.05 top→bottom
/// • Near drop shadow (black 0.32, radius 14, y 7)
///
/// Callers layer an additional `.glowShadow()` on hover for the accent glow.
@MainActor
struct AnimeCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Richer inner top highlight — 35% of card height, white 0.14 → clear
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: geo.size.height * 0.35)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            )
            // Gradient clip border
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                Color.white.opacity(0.05),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            // Near drop shadow
            .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 7)
    }
}

// MARK: - GlowShadowModifier

/// AWWWARDS-level 3-layer glow:
/// • Layer 1 — near black: always-on soft resting shadow
/// • Layer 2 — mid color.opacity(0.35) radius 16: conditional mid glow
/// • Layer 3 — far color.opacity(0.18) radius 32: conditional far bloom
@MainActor
struct GlowShadowModifier: ViewModifier {
    let color: Color
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            // Layer 1: near black resting shadow — always present
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
            // Layer 2: mid accent glow — activates on hover / selection
            .shadow(
                color: color.opacity(isActive ? 0.35 : 0.0),
                radius: isActive ? 16 : 0,
                x: 0,
                y: isActive ? 6 : 0
            )
            // Layer 3: far bloom — activates on hover / selection
            .shadow(
                color: color.opacity(isActive ? 0.18 : 0.0),
                radius: isActive ? 32 : 0,
                x: 0,
                y: isActive ? 10 : 0
            )
    }
}

// MARK: - ShimmerModifier

/// AWWWARDS-level animated shimmer — 4-stop gradient sweep:
/// [clear, white 0.16, white 0.08, clear]
/// Phase sweeps 0 → 1.6 linearly over 1.2 s, repeating forever.
@MainActor
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear,                          location: 0.0),
                        .init(color: Color.white.opacity(0.16),       location: 0.35),
                        .init(color: Color.white.opacity(0.08),       location: 0.55),
                        .init(color: .clear,                          location: 1.0),
                    ],
                    startPoint: UnitPoint(x: phase - 0.6, y: 0.5),
                    endPoint:   UnitPoint(x: phase,       y: 0.5)
                )
                .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.2)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.6
                }
            }
            .onDisappear { phase = 0 }
    }
}

// MARK: - AnimeEntranceModifier

/// Staggered easeOut entrance: fade in + slide up from 20 pt below.
/// Uses easeOut(0.28 s) rather than a spring for snappier arrival in scroll lists.
///
/// Usage:
/// ```swift
/// ForEach(items.indices, id: \.self) { i in
///     ItemView(items[i])
///         .animeEntrance(delay: Double(i) * 0.06)
/// }
/// ```
@MainActor
struct AnimeEntranceModifier: ViewModifier {
    let delay: Double
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeOut(duration: 0.28)) {
                        appeared = true
                    }
                }
            }
    }
}

// MARK: - CoverCardModifier

/// Cover-image card treatment.
///
/// Note: callers are responsible for enforcing a 2:3 aspect ratio on the
/// content frame (e.g. `.aspectRatio(2/3, contentMode: .fit)`); this modifier
/// clips, highlights, and shadows but does not impose dimensions.
@MainActor
struct CoverCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Inner top highlight
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: geo.size.height * 0.28)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            )
            // Hairline gradient border
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            // Near resting drop shadow
            .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 6)
    }
}

// MARK: - MangaBadgeModifier

/// Small filled capsule styling for count/status badges.
/// Gradient fill + glow shadow for the AWWWARDS look.
@MainActor
struct MangaBadgeModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.mangaLabel)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.70)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: color.opacity(0.40), radius: 6, x: 0, y: 2)
            .shadow(color: color.opacity(0.20), radius: 12, x: 0, y: 4)
    }
}

// MARK: - GlassSectionModifier

/// Section container glass surface — slightly stronger fill than glassCard,
/// intended for grouping rows or grids within a larger layout.
@MainActor
struct GlassSectionModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.appAccent.opacity(0.18), location: 0.0),
                                .init(color: Color.appAccent.opacity(0.08), location: 0.5),
                                .init(color: Color.appAccent.opacity(0.02), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.appAccent.opacity(0.32),
                                Color.appAccent.opacity(0.08),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
            // Inner top-edge accent highlight
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.16), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            }
            // Near shadow
            .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 5)
            // Far ambient accent shadow
            .shadow(color: Color.appAccent.opacity(0.12), radius: 20, x: 0, y: 8)
    }
}

// MARK: - PremiumCardModifier

/// AWWWARDS-level premium card surface:
/// • 2-stop topLeading→bottomTrailing gradient fill
/// • 2-stop accent gradient border: accent 0.40 → accent 0.10, top→bottom
/// • 2-layer shadow: near accent + far black
@MainActor
struct PremiumCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.primary.opacity(0.10), location: 0.0),
                                .init(color: Color.primary.opacity(0.04), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.40),
                                accent.opacity(0.10),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
            // Near accent shadow
            .shadow(color: accent.opacity(0.18), radius: 12, x: 0, y: 4)
            // Far black shadow
            .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 8)
    }
}

extension View {
    func premiumCard(cornerRadius: CGFloat = 16, accent: Color = .appAccent) -> some View {
        modifier(PremiumCardModifier(cornerRadius: cornerRadius, accent: accent))
    }
}

// MARK: - ReaderSeekbar (preserved exactly)

/// Bottom-of-reader seekbar. Drag the slider to jump to any page. Use the
/// `onScrub` callback for modes (like webtoon) where you also need to scroll
/// to the matching position.
@MainActor
struct ReaderSeekbar: View {
    @Binding var page: Int          // 0-based
    let pageCount: Int
    var rtl: Bool = false
    var onScrub: ((Int) -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @State private var isHovering = false

    var body: some View {
        let safeCount = max(pageCount, 1)
        // Slider value is Double; we round before assignment.
        let binding = Binding<Double>(
            get: { Double(page) },
            set: { newValue in
                let target = max(0, min(safeCount - 1, Int(newValue.rounded())))
                if target != page {
                    page = target
                    onScrub?(target)
                }
            }
        )
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text("\(page + 1)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(minWidth: 28, alignment: .trailing)
                    .foregroundStyle(.primary)
                slider(binding: binding, max: Double(safeCount - 1))
                    .frame(maxWidth: 420)
                Text("\(safeCount)")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 28, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassOverlay(cornerRadius: 999)
        .opacity(isHovering ? 1.0 : 0.85)
        .scaleEffect(isHovering ? 1.0 : 0.97)
        .animation(.glass, value: isHovering)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func slider(binding: Binding<Double>, max: Double) -> some View {
        if rtl {
            // SwiftUI Slider doesn't natively flip; rotate the whole control
            // 180° so dragging right→left advances the page in manga-mode.
            Slider(value: binding, in: 0...max, step: 1)
                .scaleEffect(x: -1, y: 1, anchor: .center)
                .accessibilityLabel("Page slider (right-to-left)")
        } else {
            Slider(value: binding, in: 0...max, step: 1)
                .accessibilityLabel("Page slider")
        }
    }
}

// MARK: - coverAmbientBackground

extension View {
    /// AWWWARDS-level ambient background used across all detail/reader/explore views.
    /// Layers three radial gradients over a solid base and cross-fades on colour changes:
    /// • primary top-trailing
    /// • secondary bottom-leading
    /// • depth spot bottom-center (dark mode only)
    func coverAmbientBackground(primary: Color, secondary: Color) -> some View {
        background(
            ZStack {
                Color.appBackground
                RadialGradient(
                    colors: [primary.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 450
                )
                RadialGradient(
                    colors: [secondary.opacity(0.14), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 380
                )
                // 3rd depth spot — bottom-center for extra warmth in dark mode
                _CoverAmbientDepthSpot(primary: primary)
            }
            .animation(.easeInOut(duration: 0.6), value: primary)
            .ignoresSafeArea()
        )
    }
}

/// Internal helper that reads colorScheme to conditionally render the
/// bottom-center depth gradient without making coverAmbientBackground itself
/// a ViewModifier that needs @Environment injection.
@MainActor
private struct _CoverAmbientDepthSpot: View {
    @Environment(\.colorScheme) private var colorScheme
    let primary: Color

    var body: some View {
        if colorScheme == .dark {
            RadialGradient(
                colors: [primary.opacity(0.10), .clear],
                center: .bottom,
                startRadius: 0,
                endRadius: 300
            )
        }
    }
}

// MARK: - Font Typography Presets

extension Font {
    /// Hero display text — section headers, empty-state titles.
    static var mangaHero: Font { .system(size: 34, weight: .bold, design: .rounded) }
    /// Largest display text — splash screens, onboarding.
    static var mangaDisplay: Font { .system(size: 42, weight: .black, design: .rounded) }
    /// Card / sheet titles.
    static var mangaTitle: Font { .system(size: 20, weight: .bold, design: .rounded) }
    /// Small card labels — chapter names, grid captions.
    static var mangaCardTitle: Font { .subheadline.weight(.semibold) }
    /// Metadata lines — chapter count, source name, date strings.
    static var mangaMeta: Font { .caption }
    /// Status and genre badge labels.
    static var mangaBadge: Font { .caption2.weight(.bold) }
    /// Compact semibold label — used inside MangaBadgeModifier.
    static var mangaLabel: Font { .caption2.weight(.semibold) }
}

// MARK: - neonGlow modifier

extension View {
    /// Stacked neon glow for interactive elements — buttons, selected cards.
    /// Apply on top of `.glowShadow()` or standalone for a pure neon look.
    /// - Parameters:
    ///   - color: The accent colour for the glow.
    ///   - radius: Outer glow radius (inner is radius / 2). Default `10`.
    func neonGlow(color: Color, radius: CGFloat = 10) -> some View {
        self
            .shadow(color: color.opacity(0.0), radius: 0)          // base layer
            .shadow(color: color.opacity(0.6), radius: radius / 2, y: 0)
            .shadow(color: color.opacity(0.3), radius: radius,     y: 0)
    }
}

// MARK: - FlowLayout (preserved exactly)

/// Tiny flow layout — wraps children onto multiple lines when they overflow.
/// Used for tag chips, filter pills, etc.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isInfinite ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
