import SwiftUI

public extension EnvironmentValues {
    /// False draws every arrival animation (the split-flap scramble, the deck's count-up) already
    /// settled, exactly as Reduce Motion does. Reduce Motion itself is read-only in SwiftUI's
    /// environment, so this is how a preview or a snapshot test asks for the settled frame.
    @Entry var playsArrivalAnimations: Bool = true
}
