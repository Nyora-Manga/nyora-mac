import SwiftUI

@MainActor
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var appearing = false
    @State private var showConflictDialog = false
    @State private var pendingIdToken: String? = nil
    
    var body: some View {
        ZStack {
            // MARK: - Animated Aurora Background
            AuroraBackground()
                .ignoresSafeArea()
            
            // MARK: - Content Card
            VStack(spacing: 40) {
                // Header
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent.opacity(0.2))
                            .frame(width: 120, height: 120)
                            .blur(radius: 24)
                        
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 92, height: 92)
                            .shadow(color: Color.appAccent.opacity(0.4), radius: 16, y: 8)
                    }
                    .scaleEffect(appearing ? 1 : 0.7)
                    .opacity(appearing ? 1 : 0)
                    
                    VStack(spacing: 8) {
                        Text("Welcome to Nyora")
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.primary, .primary.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        Text("The ultimate cross-platform manga reader")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .offset(y: appearing ? 0 : 24)
                    .opacity(appearing ? 1 : 0)
                }
                
                // Buttons
                VStack(spacing: 18) {
                    let isBusy = appState.isSupabaseSigningIn || appState.isSupabaseSyncing
                    
                    // Google Sign In
                    Button {
                        if !isBusy { signIn() }
                    } label: {
                        HStack(spacing: 12) {
                            if appState.isSupabaseSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                                    .brightness(1)
                            } else {
                                Image(systemName: "g.circle.fill")
                                    .font(.title2)
                            }
                            Text("Sign in with Google")
                                .font(.headline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.appAccent, Color.appAccent.opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Color.appAccent.opacity(0.4), radius: 10, y: 5)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(isBusy ? 0.5 : 1.0)
                    .scaleEffect(appearing ? 1 : 0.9)
                    .keyboardShortcut("s", modifiers: [.command])
                    
                    // Backup Restore
                    Button {
                        if !isBusy {
                            Task {
                                if await appState.importBackup() {
                                    finish()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("Restore from Backup")
                        }
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(isBusy ? 0.5 : 1.0)
                    .scaleEffect(appearing ? 1 : 0.9)
                    
                    // Guest Mode
                    Button {
                        if !isBusy { finish() }
                    } label: {
                        Text("Continue as Guest")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(Capsule().fill(.quaternary.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .opacity(isBusy ? 0.5 : 1.0)
                    .padding(.top, 4)
                    .opacity(appearing ? 1 : 0)

                    if let status = appState.statusMessage {
                        HStack(spacing: 8) {
                            if appState.isSupabaseSyncing {
                                ProgressView().controlSize(.small)
                            }
                            Text(status)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 12)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: 340)
            }
            .padding(60)
            .background {
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 50, y: 25)
                    .overlay {
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.3), .clear, .white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    }
            }
            .frame(maxWidth: 600)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.75).delay(0.2)) {
                appearing = true
            }
        }
        .confirmationDialog(
            "Local Data Detected",
            isPresented: $showConflictDialog,
            titleVisibility: .visible
        ) {
            Button("Merge Local & Cloud") {
                confirmSignIn(mode: .merge)
            }
            Button("Replace Local with Cloud", role: .destructive) {
                confirmSignIn(mode: .replace)
            }
            Button("Cancel", role: .cancel) {
                pendingIdToken = nil
            }
        } message: {
            Text("You already have library data on this device. Would you like to merge it with your cloud library, or replace this local data with what's in the cloud?")
        }
    }
    
    private enum SignInMode { case merge, replace }
    
    private func signIn() {
        guard !appState.isSupabaseSigningIn else { return }
        Task {
            appState.isSupabaseSigningIn = true
            appState.statusMessage = "Opening Google sign-in..."
            defer { appState.isSupabaseSigningIn = false }

            let serverClientID = appState.supabaseStatus?.googleServerClientId ?? ""
            switch await SupabaseGoogleAuthHelper.signIn(serverClientID: serverClientID) {
            case .success(let idToken):
                if await appState.supabaseHasLocalData() {
                    self.pendingIdToken = idToken
                    self.showConflictDialog = true
                } else {
                    let ok = await appState.supabaseSignIn(idToken: idToken)
                    if ok {
                        await appState.supabaseSync()
                        finish()
                    }
                }
            case .cancelled:
                appState.statusMessage = "Google sign-in canceled"
            case .failure(let message):
                appState.statusMessage = "Google sign-in failed: \(message)"
            }
        }
    }

    private func confirmSignIn(mode: SignInMode) {
        guard let idToken = pendingIdToken else { return }
        Task {
            let ok = await appState.supabaseSignIn(idToken: idToken)
            if ok {
                if mode == .replace {
                    await appState.supabaseRestoreFromCloud()
                } else {
                    await appState.supabaseSync()
                }
                finish()
            }
            self.pendingIdToken = nil
        }
    }

    private func finish() {
        withAnimation {
            appState.readerPrefs.isOnboardingComplete = true
        }
    }
}

// MARK: - Aurora Background Helper

@MainActor
private struct AuroraBackground: View {
    @State private var animate = false
    
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            
            // Large blurred blobs
            Circle()
                .fill(Color.appAccent.opacity(0.15))
                .frame(width: 600, height: 600)
                .blur(radius: 100)
                .offset(x: animate ? 200 : -200, y: animate ? -100 : 100)
            
            Circle()
                .fill(Color.purple.opacity(0.1))
                .frame(width: 500, height: 500)
                .blur(radius: 120)
                .offset(x: animate ? -200 : 200, y: animate ? 100 : -100)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
