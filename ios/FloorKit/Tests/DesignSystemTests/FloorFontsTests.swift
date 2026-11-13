import CoreText
import Testing
@testable import DesignSystem

@Suite("Bundled type")
struct FloorFontsTests {
    /// Every face the display styles name must register and resolve under that PostScript name,
    /// or `Typography` silently drops to the system fallback.
    @Test func registersEveryBarlowCondensedFace() {
        #expect(FloorFonts.register())
        for face in FloorFonts.Face.allCases {
            let font = CTFontCreateWithName(face.postScriptName as CFString, 20, nil)
            #expect(CTFontCopyPostScriptName(font) as String == face.postScriptName)
        }
    }
}
