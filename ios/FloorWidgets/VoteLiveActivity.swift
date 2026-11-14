import ActivityKit
import DesignSystem
import LiveActivity
import Models
import SwiftUI
import WidgetKit

// The Live Activity and Dynamic Island from the locked design, sections "A · Live Activity" and
// "B · Dynamic Island" of https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn. What they say and how
// they are drawn is FloorKit's `LiveActivity` (tested there, snapshot-tested there); this is
// ActivityKit's configuration only.

struct VoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoteActivityAttributes.self) { context in
            VoteActivityLockScreen(attributes: context.attributes, content: context.state)
                .activityBackgroundTint(Palette.liveActivity.opacity(Palette.liveActivityOpacity))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(FloorLink.vote(id: context.attributes.voteId).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ChamberTile(size: 22).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(VoteActivityText.header(context.attributes).uppercased())
                        .font(Typography.label(12))
                        .tracking(1.2)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .litObject()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoteActivityStatus(content: context.state).litObject().padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoteActivityExpanded(attributes: context.attributes, content: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                VoteActivityCompactLeading(attributes: context.attributes, content: context.state)
            } compactTrailing: {
                VoteActivityCompactTrailing(content: context.state)
            } minimal: {
                VoteActivityMinimal()
            }
            .widgetURL(FloorLink.vote(id: context.attributes.voteId).url)
            .keylineTint(Palette.threshold)
        }
    }
}
