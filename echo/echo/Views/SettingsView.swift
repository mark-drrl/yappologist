import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var apiKey: String = ""
    @State private var resourceName: String = ""
    @State private var saved = false
    @State private var isChecking = false
    @State private var errorMsg: String?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "The Yappologist \(short) (build \(build))"
    }

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $themeManager.userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
            } header: {
                Text("Name")
                    .font(.system(size: 13, weight: .semibold))
            } footer: {
                Text(themeManager.greeting)
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
            }

            Section {
                Picker("Theme", selection: $themeManager.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.label, systemImage: theme.icon).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            } header: {
                Text("Theme")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                TextField("Azure resource name", text: $resourceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)

                SecureField("Paste your Azure Speech key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)

                HStack {
                    EchoButton(isChecking ? "Checking…" : "Save", icon: "key") {
                        saveKey()
                    }
                    .disabled(isChecking)
                    if saved {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12, weight: .medium))
                            .transition(.opacity)
                    }
                }

                if let err = errorMsg {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Sign out", role: .destructive) {
                    signOut()
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.system(size: 11))
            } header: {
                Text("Azure Speech")
                    .font(.system(size: 13, weight: .semibold))
            } footer: {
                Text("The resource name is the first part of your Azure endpoint, e.g. \"my-resource\" from my-resource.cognitiveservices.azure.com. Your key is stored securely in the macOS Keychain and never leaves your device.")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
            }
            Section {
                Toggle("Remove fillers (um, uh, false starts)", isOn: Binding(
                    get: { AzureSettings.cleanTranscript },
                    set: { AzureSettings.cleanTranscript = $0 }
                ))

                TextEditor(text: Binding(
                    get: { AzureSettings.vocabularyText },
                    set: { AzureSettings.vocabularyText = $0 }
                ))
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 320, height: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            } header: {
                Text("Transcription")
                    .font(.system(size: 13, weight: .semibold))
            } footer: {
                Text("Custom vocabulary: one term per line — names, places, jargon. Recognition is biased toward these, which is where transcription most often goes wrong.")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
            }

            Section {
                TextEditor(text: Binding(
                    get: { CorrectionSettings.rulesText },
                    set: { CorrectionSettings.rulesText = $0 }
                ))
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 320, height: 70)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            } header: {
                Text("Auto-corrections")
                    .font(.system(size: 13, weight: .semibold))
            } footer: {
                Text("One rule per line, written as wrong => right. Applied to every new transcript, so a name the model always mishears only has to be fixed once.")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
            }

            Section {
                Toggle("Include timestamps", isOn: Binding(
                    get: { ExportSettings.includeTimestamps },
                    set: { ExportSettings.includeTimestamps = $0 }
                ))
                Toggle("Include speaker labels", isOn: Binding(
                    get: { ExportSettings.includeSpeakerLabels },
                    set: { ExportSettings.includeSpeakerLabels = $0 }
                ))
            } header: {
                Text("Export")
                    .font(.system(size: 13, weight: .semibold))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn both off for plain prose with no headers.")
                    // So she can say which build she's on when something goes wrong.
                    Text(appVersion)
                        .foregroundColor(.secondary.opacity(0.7))
                        .textSelection(.enabled)
                }
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
        .onAppear {
            apiKey = KeychainHelper.load() ?? ""
            resourceName = AzureSettings.resourceName
        }
    }

    /// Checks the credentials against Azure before storing them, so a bad paste
    /// is caught here rather than by a failed transcription later.
    private func saveKey() {
        errorMsg = nil
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        let trimmedResource = resourceName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMsg = "Key cannot be empty."
            return
        }
        guard !trimmedResource.isEmpty else {
            errorMsg = "Resource name cannot be empty."
            return
        }

        isChecking = true
        Task {
            do {
                try await TranscribeClient.validate(resourceName: trimmedResource, apiKey: trimmed)
                AzureSettings.resourceName = trimmedResource
                try KeychainHelper.save(trimmed)
                isChecking = false
                withAnimation { saved = true }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation { saved = false }
            } catch {
                isChecking = false
                errorMsg = error.localizedDescription
            }
        }
    }

    /// Forgets the credentials and returns to the welcome screen. Transcripts
    /// already saved are left alone.
    private func signOut() {
        KeychainHelper.delete()
        AzureSettings.resourceName = ""
        apiKey = ""
        resourceName = ""
        saved = false
        errorMsg = nil
        themeManager.hasOnboarded = false
    }
}
