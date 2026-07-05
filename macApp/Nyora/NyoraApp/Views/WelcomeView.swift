import SwiftUI

@MainActor
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var appearing = false
    @State private var showConflictDialog = false
    @State private var email = ""
    @State private var password = ""
    
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
                        
                        Image(bundleResource: "NyoraLogo")
                            .resizable()
                            .frame(width: 92, height: 92)
                            .clipShape(Circle())
                            .shadow(color: Color.appAccent.opacity(0.4), radius: 16, y: 8)
                    }
                    .scaleEffect(appearing ? 1 : 0.7)
                    .opacity(appearing ? 1 : 0)
                    
                    VStack(spacing: 12) {
                        Text("破壊 · Manga, anywhere the night takes you")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(Color.appAccent)

                        Text("Read like the world can wait.")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.primary, .primary.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        Text("Nyora pulls hundreds of sources into one quiet shelf and remembers exactly where you stopped — on your phone, your tablet, your desk. Sign in to sync and back it up, or just start reading.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 400)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .offset(y: appearing ? 0 : 24)
                    .opacity(appearing ? 1 : 0)
                }
                
                // Buttons
                VStack(spacing: 18) {
                    let isBusy = appState.isSupabaseSigningIn || appState.isSupabaseSyncing
                    
                    // Email / password
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .disableAutocorrection(true)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)

                    Button {
                        if !isBusy { signIn(register: false) }
                    } label: {
                        HStack(spacing: 12) {
                            if appState.isSupabaseSigningIn {
                                ProgressView().controlSize(.small)
                            }
                            Text("Sign in").font(.headline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.appAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Color.appAccent.opacity(0.35), radius: 10, y: 5)
                    }
                    .buttonStyle(.plain)
                    .opacity(isBusy ? 0.5 : 1.0)
                    .scaleEffect(appearing ? 1 : 0.9)
                    .keyboardShortcut(.return)

                    Button {
                        if !isBusy { signIn(register: true) }
                    } label: {
                        Text("Create account")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    // Secondary action ON the glass panel — a bordered (not glass)
                    // button; glass-on-glass would double-frost.
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .opacity(isBusy ? 0.5 : 1.0)

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
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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
            .adaptiveGlass(.rect(cornerRadius: 40))
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
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You already have library data on this device. Would you like to merge it with your cloud library, or replace this local data with what's in the cloud?")
        }
    }
    
    private enum SignInMode { case merge, replace }
    
    private func signIn(register: Bool) {
        guard !appState.isSupabaseSigningIn else { return }
        let em = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !em.isEmpty, !password.isEmpty else {
            appState.statusMessage = "Enter your email and password"
            return
        }
        Task {
            let ok = register
                ? await appState.supabaseRegister(email: em, password: password)
                : await appState.supabaseSignIn(email: em, password: password)
            guard ok else { return }
            if await appState.supabaseHasLocalData() {
                self.showConflictDialog = true   // already authed; ask merge vs replace
            } else {
                await appState.supabaseSync()
                finish()
            }
        }
    }

    private func confirmSignIn(mode: SignInMode) {
        Task {
            if mode == .replace {
                await appState.supabaseRestoreFromCloud()
            } else {
                await appState.supabaseSync()
            }
            finish()
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
