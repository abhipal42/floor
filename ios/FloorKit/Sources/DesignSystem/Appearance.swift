import SwiftUI

/// The reader's choice of light or dark, or the system's.
///
/// Stored in `UserDefaults` under ``storageKey`` as its raw value, so `@AppStorage` reads it in the
/// app's root (which applies it to the window) and in ``AppearanceMenu`` (which changes it).
public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let storageKey = "appearance"

    public var id: String { rawValue }

    /// An unknown or missing stored value means the system's.
    public init(stored: String?) {
        self = stored.flatMap(Appearance.init(rawValue:)) ?? .system
    }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// nil follows the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The round button beside the district chip on Home: System, Light or Dark.
public struct AppearanceMenu: View {
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    public init() {}

    public var body: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
        } label: {
            Image(systemName: appearance.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(Palette.text.opacity(0.08), in: .circle)
        }
        .accessibilityLabel("Appearance")
        .accessibilityValue(appearance.label)
    }
}
