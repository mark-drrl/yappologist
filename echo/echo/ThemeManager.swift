import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, cute
    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        case .cute:  return "Cute"
        }
    }

    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark:  return "moon.stars.fill"
        case .cute:  return "sparkles"
        }
    }

    /// What SwiftUI color scheme to force. Cute rides on top of light.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        case .cute:  return .light
        }
    }

    /// Primary accent used across buttons and badges.
    var accent: Color {
        switch self {
        case .cute: return Color(red: 0.96, green: 0.52, blue: 0.66) // pastel pink
        default:    return Color(red: 0.38, green: 0.51, blue: 0.93) // soft indigo
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var userName: String {
        didSet { UserDefaults.standard.set(userName, forKey: Keys.name) }
    }
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    private enum Keys {
        static let theme = "appTheme"
        static let name = "userName"
        static let onboarded = "hasOnboarded"
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Keys.theme) ?? AppTheme.light.rawValue
        self.theme = AppTheme(rawValue: raw) ?? .light
        self.userName = UserDefaults.standard.string(forKey: Keys.name) ?? ""
        self.hasOnboarded = UserDefaults.standard.bool(forKey: Keys.onboarded)
    }

    /// "Hello Doc <name>" — always Doc-prefixed.
    var greeting: String {
        let trimmed = userName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Hello Doc" : "Hello Doc \(trimmed)"
    }
}
