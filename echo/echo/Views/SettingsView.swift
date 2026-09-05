import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var apiKey: String = ""
    @State private var resourceName: String = ""
    @State private var saved = false
    @State private var errorMsg: String?

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
                    EchoButton("Save", icon: "key") {
                        saveKey()
                    }
                    if saved {
                        Label("Saved!", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12, weight: .medium))
                            .transition(.opacity)
                    }
                }

                if let err = errorMsg {
                    Text(err).foregroundColor(.red).font(.system(size: 11))
                }

                Button("Clear saved key", role: .destructive) {
                    KeychainHelper.delete()
                    apiKey = ""
                    saved = false
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
                Text("Turn both off for plain prose with no headers.")
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
        do {
            AzureSettings.resourceName = trimmedResource
            try KeychainHelper.save(trimmed)
            withAnimation { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { saved = false }
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
