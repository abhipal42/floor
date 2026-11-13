import CoreText
import Foundation
import SwiftUI

/// Registers the bundled Barlow Condensed faces with the process.
///
/// At runtime rather than through `UIAppFonts`, because the fonts live in this package's resource
/// bundle: the app's Info.plist cannot name a file in another bundle, and SwiftUI previews and
/// `swift test` never read the app's Info.plist at all. Registering once, here, covers all three.
public enum FloorFonts {
    /// The bundled faces: 600/700/800 roman, 800/900 italic.
    public enum Face: String, CaseIterable, Sendable {
        case semiBold = "BarlowCondensed-SemiBold"
        case bold = "BarlowCondensed-Bold"
        case extraBold = "BarlowCondensed-ExtraBold"
        case extraBoldItalic = "BarlowCondensed-ExtraBoldItalic"
        case blackItalic = "BarlowCondensed-BlackItalic"

        /// The file name and the PostScript name are the same for every face in the family.
        public var postScriptName: String { rawValue }

        var isItalic: Bool { self == .extraBoldItalic || self == .blackItalic }

        var fallbackWeight: Font.Weight {
            switch self {
            case .semiBold: .semibold
            case .bold: .bold
            case .extraBold, .extraBoldItalic: .heavy
            case .blackItalic: .black
            }
        }
    }

    /// True when every face is available, registering them on first call.
    @discardableResult
    public static func register() -> Bool { registered }

    private static let registered: Bool = {
        // `map` before checking, so one missing file does not stop the rest registering.
        Face.allCases.map { face in
            guard let url = Bundle.module.url(forResource: face.rawValue, withExtension: "ttf", subdirectory: "Fonts")
            else { return false }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            // Already registered (by an earlier call in another module's bundle copy, or a
            // preview reload) is success, not failure.
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            return code == CTFontManagerError.alreadyRegistered.rawValue
        }.allSatisfy { $0 }
    }()
}
