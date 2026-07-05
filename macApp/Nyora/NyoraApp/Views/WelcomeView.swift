import SwiftUI
import AppKit

//
//  WelcomeView.swift  — Nyora (macOS)
//
//  First-run onboarding, mirroring the iOS `NyoraStartView` + the web's
//  `populatePreferencesCard`, adapted for a desktop window.
//
//  Two layers, shown once (gated by `readerPrefs.isOnboardingComplete`, which
//  RootView reads to decide whether to present this view):
//
//    Layer 1 (WelcomeView)      — monochrome editorial hero + auth: Sign in /
//                                 Create account (existing Supabase auth),
//                                 Restore from backup, and Continue as guest.
//                                 Everyone proceeds to Layer 2.
//    Layer 2 (PreferencesOnboardingView) — fetch the source catalog, offer a
//                                 "Show 18+ sources" toggle (default off) plus
//                                 multi-select language chips with counts, a live
//                                 "N sources will be added" count, and a CTA that
//                                 seeds exactly the matching sources, persists the
//                                 18+ preference, then finishes onboarding.
//
//  Visual design: monochrome (black/white/gray via AppKit semantic colours),
//  bold system headings — no Poppins bundle on macOS, so system `.black` weight
//  stands in for the iOS editorial wordmark.
//

// MARK: - Monochrome palette

/// Deliberately colourless: `ink` is the foreground (black in light, white in
/// dark), `paper` the background (the inverse). All accents are grays.
enum Mono {
    static let ink = Color(nsColor: .labelColor)
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let inkInverse = Color(nsColor: .windowBackgroundColor)
    static let subtle = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let field = Color(nsColor: .controlBackgroundColor)
    static let chipBase = Color(nsColor: .textBackgroundColor)
}

private extension Font {
    /// System stand-in for the iOS Poppins headings — bold/black weights carry
    /// the editorial feel without a bundled font.
    static func onboard(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Layer 1 — auth / welcome

@MainActor
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    private enum Mode: Equatable { case landing, signIn, signUp }

    @State private var mode: Mode = .landing
    @State private var email = ""
    @State private var password = ""
    @State private var appeared = false
    @State private var showConflictDialog = false
    /// Layer 2: once the user is "in" (signed in / registered / guest) we swap
    /// the auth card for the Preferences step, which seeds sources then finishes.
    @State private var showingPreferences = false

    var body: some View {
        Group {
            if showingPreferences {
                PreferencesOnboardingView(context: .onboarding) { finishOnboarding() }
                    .environmentObject(appState)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                authBody
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showingPreferences)
    }

    // MARK: Auth body

    private var authBody: some View {
        ZStack {
            Mono.paper.ignoresSafeArea()
            backgroundWordmark

            VStack(alignment: .leading, spacing: 28) {
                brand
                card
                legalFootnote
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(48)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
        }
        .animation(.easeInOut(duration: 0.28), value: mode)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.easeOut(duration: 0.55)) { appeared = true }
        }
        .confirmationDialog(
            "Local Data Detected",
            isPresented: $showConflictDialog,
            titleVisibility: .visible
        ) {
            Button("Merge Local & Cloud") { confirmSignIn(mode: .merge) }
            Button("Replace Local with Cloud", role: .destructive) { confirmSignIn(mode: .replace) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You already have library data on this device. Merge it with your cloud library, or replace this local data with what's in the cloud?")
        }
    }

    /// An oversized ghost "N" bleeding off the trailing edge — editorial flourish.
    private var backgroundWordmark: some View {
        Text("N")
            .font(.onboard(560, weight: .black))
            .foregroundStyle(Mono.ink.opacity(0.035))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(x: 160, y: -80)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MANGA · EVERYWHERE")
                .font(.onboard(12, weight: .semibold))
                .tracking(2.5)
                .foregroundStyle(Mono.subtle)

            Text("Nyora")
                .font(.onboard(72, weight: .black))
                .foregroundStyle(Mono.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Rectangle()
                .fill(Mono.ink)
                .frame(width: 48, height: 3)

            Text("Your library, in sync — read anywhere, pick up where you left off.")
                .font(.onboard(15, weight: .regular))
                .foregroundStyle(Mono.subtle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .landing {
                landingButtons
            } else {
                authForm
            }

            if let status = appState.statusMessage {
                HStack(spacing: 8) {
                    if appState.isSupabaseSyncing || appState.isSupabaseSigningIn {
                        ProgressView().controlSize(.small)
                    }
                    Text(status)
                        .font(.onboard(13, weight: .medium))
                        .foregroundStyle(Mono.subtle)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Landing

    private var landingButtons: some View {
        let isBusy = appState.isSupabaseSigningIn || appState.isSupabaseSyncing
        return VStack(spacing: 12) {
            primaryButton(title: "Sign in") { switchTo(.signIn) }
            secondaryButton(title: "Create account") { switchTo(.signUp) }

            secondaryButton(title: "Restore from backup") {
                Task {
                    if await appState.importBackup() { enterPreferences() }
                }
            }

            Button {
                if !isBusy { enterPreferences() }
            } label: {
                Text("Continue as guest")
                    .font(.onboard(14, weight: .medium))
                    .foregroundStyle(Mono.subtle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .opacity(isBusy ? 0.5 : 1)
        .disabled(isBusy)
    }

    // MARK: Auth form

    private var authForm: some View {
        let isBusy = appState.isSupabaseSigningIn || appState.isSupabaseSyncing
        return VStack(alignment: .leading, spacing: 18) {
            Text(mode == .signUp ? "Create account" : "Welcome back")
                .font(.onboard(26, weight: .bold))
                .foregroundStyle(Mono.ink)

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disableAutocorrection(true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .onSubmit { signIn(register: mode == .signUp) }
            }

            primaryButton(
                title: mode == .signUp ? "Create account" : "Sign in",
                busy: isBusy,
                disabled: email.isEmpty || password.isEmpty
            ) {
                signIn(register: mode == .signUp)
            }
            .keyboardShortcut(.return)

            Button {
                switchTo(.landing)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.onboard(14, weight: .medium))
                }
                .foregroundStyle(Mono.subtle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    // MARK: Reusable controls

    private func primaryButton(
        title: String,
        busy: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).font(.onboard(15, weight: .semibold)).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.small).tint(Mono.inkInverse) }
            }
            .foregroundStyle(Mono.inkInverse)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Mono.ink))
            .opacity(disabled || busy ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.onboard(15, weight: .semibold))
                .foregroundStyle(Mono.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Mono.ink.opacity(0.35), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var legalFootnote: some View {
        Text("By continuing you agree to sync your library with Nyora.")
            .font(.onboard(11, weight: .regular))
            .foregroundStyle(Mono.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func switchTo(_ newMode: Mode) {
        appState.statusMessage = nil
        mode = newMode
    }

    /// Advance from auth (Layer 1) to the Preferences step (Layer 2).
    private func enterPreferences() {
        appState.statusMessage = nil
        showingPreferences = true
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
            password = ""
            if await appState.supabaseHasLocalData() {
                showConflictDialog = true   // already authed; ask merge vs replace
            } else {
                await appState.supabaseSync()
                enterPreferences()
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
            enterPreferences()
        }
    }

    /// Called by Layer 2 once preferences are applied — persist the onboarding
    /// flag so RootView swaps to the main UI.
    private func finishOnboarding() {
        withAnimation { appState.readerPrefs.isOnboardingComplete = true }
    }
}

// MARK: - Layer 2 — preferences (reusable)

/// Second onboarding layer, mirroring the web's `populatePreferencesCard`: a
/// "Show 18+ sources" toggle (default off) + multi-select language chips with
/// counts, a live "N sources will be added" line, and a CTA that seeds exactly
/// the matching installed sources and persists the 18+ preference before
/// finishing. Reused by the first-run flow AND by Settings' "Re-run setup".
@MainActor
struct PreferencesOnboardingView: View {
    enum Context { case onboarding, settings }

    let context: Context
    /// Called once preferences are applied (sources seeded + 18+ pref set).
    let onFinish: () -> Void

    @EnvironmentObject var appState: AppState

    @State private var catalog: [HelperCatalogEntry] = []
    @State private var loading = true
    @State private var loadFailed = false
    @State private var applying = false
    @State private var appeared = false
    @State private var didLoad = false

    /// "Show 18+ sources" — reflects the current pref (matters on re-run).
    @State private var show18 = false
    /// Selected language codes (lowercased). Empty ⇒ all languages.
    @State private var selectedLangs: Set<String> = []

    var body: some View {
        ZStack {
            Mono.paper.ignoresSafeArea()
            content.padding(48)
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            show18 = !appState.hideNsfwSources
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Lining up your sources…")
                    .font(.onboard(14, weight: .medium))
                    .foregroundStyle(Mono.subtle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 24)

                ScrollView {
                    VStack(spacing: 14) {
                        if loadFailed { fallbackCard } else { nsfwCard; languagesCard }
                    }
                    .padding(.bottom, 12)
                }

                foot.padding(.top, 12)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .onAppear {
                guard !appeared else { return }
                withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(context == .onboarding ? "STEP 02 · YOU'RE IN" : "PREFERENCES")
                .font(.onboard(12, weight: .semibold))
                .tracking(2.5)
                .foregroundStyle(Mono.subtle)

            Text(context == .onboarding ? "Preferences" : "Languages & sources")
                .font(.onboard(48, weight: .black))
                .foregroundStyle(Mono.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Rectangle().fill(Mono.ink).frame(width: 48, height: 3)

            Text(context == .onboarding
                 ? "Choose your languages and content preference — we'll line up the matching sources. Change any of this later in Settings."
                 : "Re-pick the languages you read and your content preference — this reseeds your installed sources.")
                .font(.onboard(14, weight: .regular))
                .foregroundStyle(Mono.subtle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nsfwCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show 18+ sources")
                    .font(.onboard(15, weight: .semibold))
                    .foregroundStyle(Mono.ink)
                Text("Include adult-only sources in Explore & search.")
                    .font(.onboard(13, weight: .regular))
                    .foregroundStyle(Mono.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $show18)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Mono.ink)
        }
        .padding(18)
        .background(cardBackground)
    }

    private var languagesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Languages")
                .font(.onboard(15, weight: .semibold))
                .foregroundStyle(Mono.ink)
            Text("Pick the languages you read, or keep \u{201C}All languages\u{201D}.")
                .font(.onboard(13, weight: .regular))
                .foregroundStyle(Mono.subtle)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                chip(title: "All languages", count: nil, active: selectedLangs.isEmpty) {
                    selectedLangs.removeAll()
                }
                ForEach(languageOptions, id: \.code) { option in
                    chip(title: option.label, count: option.count, active: selectedLangs.contains(option.code)) {
                        if selectedLangs.contains(option.code) {
                            selectedLangs.remove(option.code)
                        } else {
                            selectedLangs.insert(option.code)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    private var fallbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn't load the source catalog")
                .font(.onboard(15, weight: .semibold))
                .foregroundStyle(Mono.ink)
            Text("You can continue with the default sources and set your languages later in Settings. The 18+ preference below still applies.")
                .font(.onboard(13, weight: .regular))
                .foregroundStyle(Mono.subtle)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Mono.hairline).padding(.vertical, 4)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show 18+ sources")
                        .font(.onboard(14, weight: .semibold))
                        .foregroundStyle(Mono.ink)
                    Text("Include adult-only sources in Explore & search.")
                        .font(.onboard(12, weight: .regular))
                        .foregroundStyle(Mono.subtle)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $show18).toggleStyle(.switch).labelsHidden().tint(Mono.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !loadFailed {
                Text(countText)
                    .font(.onboard(14, weight: .semibold))
                    .foregroundStyle(Mono.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await applyAndFinish() }
            } label: {
                ZStack {
                    Text(context == .onboarding ? "Start reading" : "Save & apply")
                        .font(.onboard(15, weight: .semibold))
                        .opacity(applying ? 0 : 1)
                    if applying { ProgressView().controlSize(.small).tint(Mono.inkInverse) }
                }
                .foregroundStyle(Mono.inkInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Mono.ink))
                .opacity(applying ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(applying)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Mono.field)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Mono.hairline, lineWidth: 1)
            )
    }

    private func chip(title: String, count: Int?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.onboard(13, weight: .medium)).lineLimit(1)
                if let count {
                    Text(String(count))
                        .font(.onboard(12, weight: .semibold))
                        .foregroundStyle(active ? Mono.inkInverse.opacity(0.7) : Mono.faint)
                }
            }
            .foregroundStyle(active ? Mono.inkInverse : Mono.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Mono.ink : Mono.chipBase))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? Color.clear : Mono.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Derived data

    private struct LanguageOption { let code: String; let label: String; let count: Int }

    /// Distinct languages in the catalog, respecting the 18+ toggle so counts
    /// reflect what would actually be added. Sorted by count desc, then label.
    private var languageOptions: [LanguageOption] {
        var counts: [String: Int] = [:]
        for entry in catalog where show18 || !entry.isNsfw {
            counts[langCode(entry), default: 0] += 1
        }
        return counts
            .map { LanguageOption(code: $0.key, label: languageLabel($0.key), count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// Entries matching the current selection — the set that will be seeded.
    private var matchedEntries: [HelperCatalogEntry] {
        catalog.filter {
            (selectedLangs.isEmpty || selectedLangs.contains(langCode($0))) && (show18 || !$0.isNsfw)
        }
    }

    /// The set actually seeded — falls back to "all matching the 18+ rule" so we
    /// never leave an empty shelf.
    private var seedEntries: [HelperCatalogEntry] {
        let matched = matchedEntries
        if !matched.isEmpty { return matched }
        return catalog.filter { show18 || !$0.isNsfw }
    }

    private var countText: String {
        let n = seedEntries.count
        return "\(n) source\(n == 1 ? "" : "s") will be added"
    }

    private func langCode(_ entry: HelperCatalogEntry) -> String {
        entry.lang.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func languageLabel(_ code: String) -> String {
        switch code {
        case "", "multi", "all": return "Multi-language"
        default:
            return Locale.current.localizedString(forIdentifier: code)
                ?? Locale.current.localizedString(forLanguageCode: String(code.prefix(2)))
                ?? code.uppercased()
        }
    }

    // MARK: Actions

    private func load() async {
        loading = true
        loadFailed = false
        // Prefer any catalog AppState already has; otherwise fetch fresh.
        if !appState.catalog.isEmpty {
            catalog = appState.catalog
        } else {
            catalog = (try? await appState.helper.catalog()) ?? []
        }
        loadFailed = catalog.isEmpty
        loading = false
    }

    private func applyAndFinish() async {
        applying = true
        defer { applying = false }

        // Persist the 18+ preference. `hideNsfwSources` is the runtime pref the
        // app already uses to keep adult sources out of the catalog / sidebar /
        // global search — it's the inverse of "Show 18+ sources".
        appState.hideNsfwSources = !show18

        // Seed the matching installed sources (no-op when the catalog failed to
        // load — the pre-installed defaults are left in place).
        if !loadFailed {
            await appState.seedSources(from: seedEntries)
        }

        onFinish()
    }
}
