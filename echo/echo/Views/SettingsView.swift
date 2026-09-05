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
