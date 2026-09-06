import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var themeManager: ThemeManager

    @State private var name: String = ""
    @State private var apiKey: String = ""
    @State private var resourceName: String = ""
    @State private var isSigningIn = false
    @State private var signInError: String?

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !resourceName.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var liveGreeting: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Hello Doc" : "Hello Doc \(trimmed)"
    }

    var body: some View {
        ZStack {
            ThemeBackground(theme: themeManager.theme)

            ScrollView {
                VStack(spacing: 28) {
                    // Greeting + waving hand
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(themeManager.theme.accent.opacity(0.15))
                                .frame(width: 84, height: 84)
                            Image(systemName: "waveform")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundColor(themeManager.theme.accent)
                        }
                        Text("\(liveGreeting) 👋")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: liveGreeting)
                            .multilineTextAlignment(.center)
                        Text("Welcome to The Yappologist — let's get you set up.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)

                    // Name
                    field(title: "Your name") {
                        TextField("Type your name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                    }

                    // Azure Speech credentials
                    field(title: "Azure Speech") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Resource name", text: $resourceName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))
                            SecureField("Paste the key you were given", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))
                            if let signInError {
                                Text(signInError)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Both were sent to you separately. The key is stored securely in your Mac's Keychain — you'll only enter it this once.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Theme picker
                    field(title: "Theme") {
                        HStack(spacing: 12) {
                            ForEach(AppTheme.allCases) { theme in
                                ThemeCard(theme: theme, isSelected: themeManager.theme == theme) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        themeManager.theme = theme
                                    }
                                }
                            }
                        }
                    }

                    // Continue
                    Button(action: signIn) {
                        HStack(spacing: 8) {
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                                    .colorInvert()
                            }
                            Text(isSigningIn ? "Checking…" : "Get started")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(canContinue ? themeManager.theme.accent : Color.secondary.opacity(0.3))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue || isSigningIn)
                    .padding(.top, 4)

                    Text("by Dih (Darrel aka Marga's Wife)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Verifies the credentials against Azure before letting her in, so a typo
    /// surfaces here rather than as a failed transcription later. The check sends
    /// no audio, so it costs nothing.
    private func signIn() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        // Accepts a pasted endpoint URL as well as a bare name.
        let trimmedResource = TranscribeClient.normalizedResourceName(resourceName)
        resourceName = trimmedResource   // show what was actually understood

        signInError = nil
        isSigningIn = true

        Task {
            do {
                try await TranscribeClient.validate(resourceName: trimmedResource, apiKey: trimmedKey)
                themeManager.userName = trimmedName
                AzureSettings.resourceName = trimmedResource
                try? KeychainHelper.save(trimmedKey)
                isSigningIn = false
                withAnimation(.easeInOut) {
                    themeManager.hasOnboarded = true
                }
            } catch {
                isSigningIn = false
                signInError = error.localizedDescription
            }
        }
    }
}

struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    swatch
                    Image(systemName: theme.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme == .light ? .orange : (theme == .dark ? .white : .pink))
                }
                .frame(width: 54, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(theme.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var swatch: some View {
        switch theme {
        case .light:
            Color(white: 0.96)
        case .dark:
            Color(white: 0.15)
        case .cute:
            LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.93, blue: 0.96),
                    Color(red: 0.95, green: 0.93, blue: 1.00),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
