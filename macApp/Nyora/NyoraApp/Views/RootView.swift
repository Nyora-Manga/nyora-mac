import SwiftUI
import LocalAuthentication

@MainActor
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDestination: NavDestination = .history
    @State private var isUnlocked: Bool = false
    /// Drives the split-view sidebar column so the reader's "Hide sidebar"
    /// toggle can collapse the page-thumbnail strip to a full-width page.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

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
                           let chapter = appState.activeChapter,
                           !chapter.pages.isEmpty {
                            ReaderSidebar()
                                .toolbar {
                                    // Tiny "back to navigation" button so the user
                                    // isn't trapped in reader mode.
                                    ToolbarItem(placement: .navigation) {
                                        Button {
                                            selectedDestination = .history
                                        } label: {
                                            Label("Back to Library", systemImage: "chevron.left")
                                                .labelStyle(.titleAndIcon)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help("Back to navigation")
                                    }
                                }
                        } else {
                            SidebarView(selection: $selectedDestination)
                        }
                    }
                    .navigationSplitViewColumnWidth(
                        min: 200,
                        ideal: selectedDestination == .reader ? 260 : 230,
                        max: 300
                    )
                } detail: {
                    DetailContainerView(destination: selectedDestination)
                        // Apple-strict: the content pane stays OPAQUE & legible.
                        // Glass belongs on the chrome (auto-glass sidebar/toolbar)
                        // and on floating surfaces WITHIN each page (cards, section
                        // panels) — not on the pane background, and never fully
                        // see-through.
                        .background(Color.appBackground.ignoresSafeArea())
                        .navigationSplitViewColumnWidth(min: 480, ideal: 900)
                }
            }
        }
        .navigationTitle(selectedDestination.title)
        .tint(appState.readerPrefs.effectiveAccentColor)
        .preferredColorScheme(appState.readerPrefs.effectiveAppearance)
        // No root-level opaque background: the sidebar column must stay
        // material-free to receive macOS 26 auto-glass. The DETAIL column
        // carries `Color.appBackground` itself (see detail: closure above);
        // WelcomeView draws its own background.
        .overlay(alignment: .bottom) {
            if let message = appState.statusMessage {
                StatusBanner(message: message) { appState.clearMessage() }
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
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.65), value: appState.statusMessage)
        .onChange(of: appState.pendingNavigation) { _, new in
            if let new {
                selectedDestination = new
                _ = appState.consumeNavigation()
            }
        }
        // Collapse / restore the sidebar column whenever the reader's
        // "Hide sidebar" toggle, the active destination, or the open chapter
        // changes. Only reader mode hides — every other pane keeps its sidebar.
        .onChange(of: appState.readerPrefs.hideReaderSidebar) { _, _ in syncSidebarVisibility() }
        .onChange(of: selectedDestination) { _, _ in syncSidebarVisibility() }
        .onChange(of: appState.activeChapter?.id) { _, _ in syncSidebarVisibility() }
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

    /// Collapse the split-view sidebar only while reading with a chapter open
    /// and the user's "Hide sidebar" preference on; otherwise leave it to the
    /// system default so every other pane shows its navigation column.
    private func syncSidebarVisibility() {
        let hide = selectedDestination == .reader
            && appState.readerPrefs.hideReaderSidebar
            && (appState.activeChapter?.pages.isEmpty == false)
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = hide ? .detailOnly : .automatic
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
            // Native Liquid Glass card, accent-tinted, via the shared
            // reduce-transparency helper. Replaces the regularMaterial +
            // aurora radial-gradient fills + conic angular-sweep border.
            .adaptiveGlass(.rect(cornerRadius: 28), tint: Color.appAccent)
            .shadow(color: .black.opacity(0.4), radius: 40)
        }
    }
}
