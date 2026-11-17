import Foundation
import SwiftUI

public extension EnvironmentValues {
    /// When "now" is, for a view that says "This week" or "Last week". nil is the real clock; a
    /// snapshot or a preview pins it so the words do not change with the day it runs (lesson 69:
    /// a view takes its time and zone from the environment, never from the system).
    @Entry var pinnedNow: Date? = nil
}
