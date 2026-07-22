import SwiftUI
import LocalAuthentication

@MainActor
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDestination: NavDestination = .history
    @State private var isUnlocked: Bool = false
    /// Collapse the sidebar in the immersive reader (Apple Books full-bleed).
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// The accent wash for the glass, from the chosen colour scheme. The Dynamic
    /// (`wallpaper`) scheme is deliberately left un-tinted — it derives from the desktop
    /// that already shows through the glass, so tinting it would muddy that.
    private var glassTint: Color? {
        appState.readerPrefs.accentColor == "wallpaper"
            ? nil
            : appState.readerPrefs.effectiveAccentColor
    }

    /// The pane header. Explore shows the active source's name + engine/language line
    /// (it used to set these via navigationTitle/subtitle); every other pane is just its
    /// destination title. Centralised here so one accent-styled toolbar item covers all.
    private var paneTitle: (title: String, subtitle: String?) {
        if selectedDestination == .explore,
           let sid = appState.selectedSourceId,
           let source = appState.sources.first(where: { $0.id == sid }) {
            return (source.name, "\(source.engine) · \(source.lang.uppercased())")
        }
        return (selectedDestination.title, nil)
    }

    var body: some View {
        ZStack {
            if !appState.readerPrefs.isOnboardingComplete {
                WelcomeView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    // In reader mode the left panel becomes the page-thumbnail
                    // strip. ReaderSidebar renders its own empty state when no
                    // chapter is open, so we DON'T also require an active chapter
                    // here — that double-gate was hiding the sidebar after a cold
                    // launch.
                    Group {
                        if selectedDestination == .reader,
                           appState.activeChapter?.pages.isEmpty == false {
                            // Immersive reader — sidebar is collapsed (columnVisibility
                            // .detailOnly). Render NOTHING so the page-thumbnail strip
                            // never loads (each thumb was decoding a full-res image).
                            Color.clear
                        } else {
                            SidebarView(selection: $selectedDestination)
                        }
                    }
                    // Glass mode: paint NOTHING so the native macOS sidebar vibrancy
                    // (Tahoe glass) shows on the LEFT pane too. Flat mode: solid black/white.
                    .background {
                        if !NyoraTheme.glassMode { Color.appBackground.ignoresSafeArea() }
                    }
                    .navigationSplitViewColumnWidth(
                        min: 200,
                        ideal: selectedDestination == .reader ? 260 : 230,
                        max: 300
                    )
                } detail: {
                    DetailContainerView(destination: selectedDestination)
                        // macOS 26 "glass everywhere": the content pane is native window
                        // vibrancy, so the desktop blurs through behind it like Finder.
                        // The lists inside hide their own scroll background (see each
                        // pane) so this shows through rather than being covered.
                        .windowGlassBackground(tint: glassTint)
                        .navigationSplitViewColumnWidth(min: 480, ideal: 900)
                }
            }
        }
        .navigationTitle(selectedDestination.title)
        // The pane title is drawn here, accent-coloured to mirror the sidebar's selected
        // item, because the system toolbar title can't be recoloured (system title is
        // hidden via .unified(showsTitle: false)). This is also why the header no longer
        // resizes between panes with and without a search field — it's our own view now.
        .toolbar {
            // Leading placement, not .principal — .principal centres the title; the pane
            // header belongs at the leading edge right after the sidebar toggle, where
            // the system title used to sit.
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(paneTitle.title)
                        .font(.headline)
                        .foregroundStyle(appState.readerPrefs.effectiveAccentColor)
                    if let subtitle = paneTitle.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // A title is not a control — drop the macOS 26 per-item glass capsule so it
            // reads as plain text (like Finder's title), while the real toolbar buttons
            // keep their glass bubbles.
            .sharedBackgroundVisibility(.hidden)
        }
        // Hide the toolbar's own opaque backing so the window glass (which now runs up under
        // the titlebar via .fullSizeContentView) shows through the header instead of a black
        // bar. This is what makes the header read as native glass like Finder's.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(appState.readerPrefs.effectiveAccentColor)
        .preferredColorScheme(appState.readerPrefs.effectiveAppearance)
        // No root-level opaque background: the sidebar column must stay
        // material-free to receive macOS 26 auto-glass. The DETAIL column
        // carries `Color.appBackground` itself (see detail: closure above);
        // WelcomeView draws its own background.
        .overlay(alignment: .bottom) {
            // Status toasts are a dev aid — suppressed entirely in release/prod builds.
            #if DEBUG
            if let message = appState.statusMessage {
                StatusBanner(
                    message: message,
                    actionTitle: appState.statusActionTitle,
                    onAction: appState.statusActionTitle != nil ? { appState.runStatusAction() } : nil,
                ) { appState.clearMessage() }
                    .id(message)
                    .padding(.bottom, 28)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.88, anchor: .bottom)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.92, anchor: .bottom))
                        )
                    )
            }
            #endif
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.65), value: appState.statusMessage)
        .onChange(of: appState.pendingNavigation) { _, new in
            if let new {
                selectedDestination = new
                _ = appState.consumeNavigation()
            }
        }
        // Immersive reader: collapse the sidebar for a full-bleed page; restore it
        // everywhere else.
        .onChange(of: selectedDestination) { _, dest in
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = (dest == .reader) ? .detailOnly : .automatic
            }
        }
        .onAppear {
            columnVisibility = (selectedDestination == .reader) ? .detailOnly : .automatic
        }
        .sheet(isPresented: $appState.isCatalogPresented) {
            CatalogSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isGlobalSearchPresented) {
            GlobalSearchSheet()
                .environmentObject(appState)
        }
        .overlay {
            if appState.readerPrefs.isBiometricProtectionEnabled && !isUnlocked {
                BiometricLockOverlay(onAuthenticate: authenticate)
            }
        }
        .task {
            if appState.readerPrefs.isBiometricProtectionEnabled {
                authenticate()
            } else {
                isUnlocked = true
            }
        }
        .onChange(of: appState.readerPrefs.isBiometricProtectionEnabled) { _, enabled in
            if !enabled {
                isUnlocked = true
            }
        }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Nyora") { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self.isUnlocked = true
                    }
                }
            }
        } else {
            self.isUnlocked = true
        }
    }
}

// MARK: - Status Banner

@MainActor
struct StatusBanner: View {
    let message: String
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    let onDismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            // Neon dot with glow ring
            ZStack {
                Circle()
                    .strokeBorder(Color.appAccent.opacity(0.4), lineWidth: 1)
                    .frame(width: 12, height: 12)
                    .blur(radius: 3)
                Circle()
                    .fill(Color.appAccent)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.appAccent.opacity(0.9), radius: 6)
            }

            Text(message)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let actionTitle, let onAction {
                Button(actionTitle) { onAction() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .padding(5)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        // Native Liquid Glass capsule (UNTINTED so the frosted glass reads as
        // glass — a strong accent tint made it look like a solid pill). The accent
        // lives in the neon dot + text. Routed through the shared reduce-transparency
        // helper (solid fallback when the user disables transparency).
        .adaptiveGlass(.capsule)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .shadow(color: Color.appAccent.opacity(0.12), radius: 24, y: 4)
        .frame(maxWidth: 500)
        .scaleEffect(appeared ? 1.0 : 0.88, anchor: .bottom)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.65)) {
                appeared = true
            }
        }
    }
}

// MARK: - Biometric Lock Overlay

@MainActor
private struct BiometricLockOverlay: View {
    let onAuthenticate: () -> Void
    @EnvironmentObject var appState: AppState
    @State private var isHoveringButton = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Backdrop — plain dimming scrim only. The card itself carries the
            // native Liquid Glass; a material here would double-frost behind it.
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            // Card — content drives the size. A single glass surface (the card);
            // the action inside it is a solid button, so no GlassEffectContainer
            // is needed (that's only for grouping multiple sibling glass shapes).
            VStack(spacing: 24) {
                // Icon with pulsing glow ring
                ZStack {
                    Circle()
                        .strokeBorder(
                            Color.appAccent.opacity(0.3),
                            lineWidth: 2.5
                        )
                        .frame(width: 108, height: 108)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 72))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(appState.readerPrefs.effectiveAccentColor)
                }
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1.6)
                        .repeatForever(autoreverses: false)
                    ) {
                        pulseScale = 1.15
                        pulseOpacity = 0.0
                    }
                }

                VStack(spacing: 8) {
                    Text("Nyora is Locked")
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text("Authenticate to unlock the application.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Button("Unlock App") {
                    onAuthenticate()
                }
                // This button sits ON the glass card, so it must NOT itself be
                // glass (glass-on-glass double-frosts). A solid accent prominent
                // action is the correct pairing for a control inside a glass card.
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.large)
                .scaleEffect(isHoveringButton ? 1.04 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHoveringButton)
                .onHover { hovering in
                    isHoveringButton = hovering
                }
            }
            .padding(40)
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
            // Untinted: the card holds an accent `borderedProminent` button, and an accent
            // button on an accent-tinted card blends into it. A neutral surface lets the
            // one action on this screen actually read as the action.
            .adaptiveGlass(.rect(cornerRadius: 28))
            .shadow(color: .black.opacity(0.4), radius: 40)
        }
    }
}
