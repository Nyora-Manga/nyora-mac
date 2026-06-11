import SwiftUI
import LocalAuthentication

@MainActor
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDestination: NavDestination = .history
    @State private var isUnlocked: Bool = false

    var body: some View {
        ZStack {
            if !appState.readerPrefs.isOnboardingComplete {
                WelcomeView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            } else {
                NavigationSplitView {
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
                        .navigationSplitViewColumnWidth(min: 480, ideal: 900)
                }
            }
        }
        .navigationTitle(selectedDestination.title)
        .tint(appState.readerPrefs.effectiveAccentColor)
        .preferredColorScheme(appState.readerPrefs.effectiveAppearance)
        .background(Color.appBackground.ignoresSafeArea())
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
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(
                    LinearGradient(
                        colors: [Color.appAccent.opacity(0.08), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                // Faint topLeading accent glow spot for capsule depth
                Capsule().fill(
                    RadialGradient(
                        colors: [
                            Color.appAccent.opacity(0.14),
                            Color.appAccent.opacity(0.04),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 90
                    )
                )
            }
        }
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.appAccent.opacity(0.30), Color.primary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
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
            // Backdrop
            Color.black.opacity(0.6)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            // Card — content drives the size; the material/gradient/border
            // are applied as a background so the card hugs its contents
            // instead of a greedy shape stretching to fill the screen.
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
                .scaleEffect(isHoveringButton ? 1.04 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHoveringButton)
                .onHover { hovering in
                    isHoveringButton = hovering
                }
            }
            .padding(40)
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.regularMaterial)
                    // AuroraFill: bright accent spot topLeading + dimmer spot
                    // bottomTrailing over the material for organic depth
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.appAccent.opacity(0.20),
                                    Color.appAccent.opacity(0.09),
                                    Color.appAccent.opacity(0.03),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 320
                            )
                        )
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.appAccent.opacity(0.10),
                                    Color.appAccent.opacity(0.03),
                                    .clear
                                ],
                                center: .bottomTrailing,
                                startRadius: 0,
                                endRadius: 260
                            )
                        )
                }
            }
            .overlay {
                // Conic angular sweep border — modern rotating-light edge
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color.appAccent.opacity(0.40),
                                Color.appAccent.opacity(0.10),
                                Color.appAccent.opacity(0.32),
                                Color.appAccent.opacity(0.08),
                                Color.appAccent.opacity(0.40)
                            ],
                            center: .center
                        ),
                        lineWidth: 1.0
                    )
            }
            .shadow(color: .black.opacity(0.4), radius: 40)
        }
    }
}

// MARK: - Visual Effect (keep as-is)

@MainActor
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .windowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
