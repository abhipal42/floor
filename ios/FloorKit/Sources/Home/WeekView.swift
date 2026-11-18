import DesignSystem
import Models
import Onboarding
import SwiftUI

/// The Week tab, built to v0.2.59's locked "Your picks" (<https://claude.ai/artifact/T7fxxQyFCYdPaJnewnNpT2>):
/// both chambers on one scroll. Headliners first (the Senate's bills the Daily Digest names, the
/// House's bills under a rule), then the Senate's next meeting, then the House's fast-track bills
/// as topic tiles, then anything else listed.
///
/// Where this differs from the mock, and why:
/// - Senate next shows the meeting's heading and the program's first sentence, not the mock's
///   "Vote: Anna St. John · Done": that needs the program parsed into votes, which Floor does not do.
/// - A headliner's chips are the bill's latest votes Floor has loaded; there is no "Next: final vote"
///   chip, since nothing says what comes next.
/// - Items taken off the list stay, dimmed, marked "Off the list".
public struct WeekView: View {
    @Bindable var model: WeekModel
    let votes: [FeedItem]
    let onOpenBill: (String) -> Void
    let onOpen: (HomeModel.Route) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - votes: the votes the app has loaded, for each headliner's latest-vote chips.
    ///   - onOpen: the Senate's program screen and the fast-track lists.
    public init(
        model: WeekModel, votes: [FeedItem] = [], onOpenBill: @escaping (String) -> Void,
        onOpen: @escaping (HomeModel.Route) -> Void = { _ in }
    ) {
        self.model = model
        self.votes = votes
        self.onOpenBill = onOpenBill
        self.onOpen = onOpen
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                switch model.phase {
                case .loading:
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 60)
                case let .failed(message):
                    VStack(spacing: 12) {
                        Text(message).scaledFont(13).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
                        Button("Try again") { Task { await model.load() } }
                            .scaledFont(15, weight: .semibold)
                            .foregroundStyle(Palette.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                case let .loaded(schedule):
                    if let saved = model.saved { SavedDataNote(saved) }
                    loaded(schedule)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groundGlow()
        .refreshable { await model.load() }
        .task { if model.needsRefresh { await model.load() } }
    }

    // MARK: Header

    private var header: some View {
        // At the largest sizes the week's arrows go under the title, which is capped so it never
        // breaks mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return VStack(alignment: .leading, spacing: 4) {
            layout {
                Text(model.offset == 0 ? "THIS WEEK" : model.offset == 1 ? "NEXT WEEK" : "WEEK OF")
                    .font(Typography.pageTitle)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                HStack(spacing: 10) {
                    arrow("chevron.left", to: model.offset - 1, label: "Previous week")
                    Text(range)
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                    arrow("chevron.right", to: model.offset + 1, label: "Next week")
                }
            }
            if case let .loaded(schedule) = model.phase, let summary = WeekPlan.summary(schedule) {
                Text(summary)
                    .scaledFont(13)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }

    private var range: String {
        if case let .loaded(schedule) = model.phase { return schedule.weekRange }
        return Schedule(week: model.week, house: .init(inSession: nil, items: []), senate: nil, senateReason: nil, sourceUpdatedAt: nil).weekRange
    }

    private func arrow(_ symbol: String, to offset: Int, label: String) -> some View {
        Button { Task { await model.show(offset: offset) } } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.threshold)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: The week

    @ViewBuilder
    private func loaded(_ schedule: Schedule) -> some View {
        let state = model.follows.state
        let headliners = WeekPlan.headliners(schedule, state: state, votes: votes, calendar: calendar)
        let fast = WeekPlan.fastTrack(schedule, state: state)
        let also = WeekPlan.alsoListed(schedule, state: state)
        let housePosted = schedule.house.inSession == true && !schedule.house.items.isEmpty

        if !headliners.isEmpty {
            WeekSectionHeader(title: "Headliners")
            ForEach(headliners) { headliner in
                if let id = headliner.item.billId {
                    Button { onOpenBill(id) } label: { HeadlinerCard(headliner: headliner) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the bill")
                } else {
                    HeadlinerCard(headliner: headliner)
                }
            }
        }

        senateNext(schedule)

        if !housePosted {
            WeekPlaceholder(
                title: "No floor schedule posted",
                message: "No floor schedule posted for this week. The House lists each week's bills ahead of time, and they show here once it does."
            )
            .padding(.top, 14)
            WeekPlaceholder(
                title: "Nothing you follow is scheduled",
                message: "Follow a bill or a topic and it shows here the week it reaches the floor, and you can get an alert."
            )
        }

        if !fast.isEmpty {
            let listed = fast.filter { !$0.pulled }.count
            WeekSectionHeader(title: "Fast track · \(listed)", link: "All ›", linkLabel: "All \(listed) fast-track bills") {
                onOpen(.fastTrack(nil))
            }
            Text("House bills that need two-thirds and usually pass without debate.")
                .scaledFont(12.5)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            let columns = dynamicTypeSize.isAccessibilitySize
                ? [GridItem(.flexible())]
                : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WeekPlan.tiles(fast)) { tile in
                    Button { onOpen(.fastTrack(tile.group)) } label: { FastTrackTileView(tile: tile) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }

        if !also.isEmpty {
            WeekSectionHeader(title: "Also listed")
            ForEach(also) { row in
                WeekRowButton(row: row, onOpenBill: onOpenBill)
            }
        }

        if housePosted {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.sourceLine(schedule))
                Text("Listed means it may come up: the House adds and drops items through the week.")
            }
            .scaledFont(10.5, weight: .medium)
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func senateNext(_ schedule: Schedule) -> some View {
        if let meeting = WeekPlan.senateNext(schedule.senate, today: model.today) {
            WeekSectionHeader(title: "Senate next", link: "Program ›", linkLabel: "The Senate's program") {
                onOpen(.weekSenate)
            }
            SenateNextCard(meeting: meeting, today: model.today)
        } else {
            WeekSectionHeader(title: "Senate next")
            WeekPlaceholder(
                title: "No Senate meeting posted",
                message: schedule.senateReason ?? "The Senate hasn't named a meeting in this week."
            )
        }
    }

    static func sourceLine(_ schedule: Schedule) -> String {
        let updated = schedule.sourceUpdatedAt.flatMap(Formats.instant).map {
            $0.formatted(Date.FormatStyle(timeZone: WeekPlan.washington).month(.abbreviated).day())
        }
        return ["Source: House Majority Leader", updated.map { "updated \($0)" }].compactMap(\.self).joined(separator: ", ")
    }
}

// MARK: - Pieces

/// A Week section's title (`HEADLINERS`, `FAST TRACK · 13`) with an optional link at the right.
struct WeekSectionHeader: View {
    let title: String
    var link: String?
    var linkLabel: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(Typography.display(19, weight: .extraBold))
                .tracking(0.4)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let link {
                Button(action: action) {
                    Text(link)
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(Palette.yea)
                        .frame(minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(linkLabel ?? link)
            }
        }
        .padding(.top, 14)
    }
}

/// A headliner's hero card: a 4pt top edge in the topic's colour (gold when you follow it), the cite
/// chip and the chamber label, the title in display caps, the context, and the latest votes.
struct HeadlinerCard: View {
    let headliner: Headliner
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let top = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        VStack(alignment: .leading, spacing: 0) {
            top {
                SkewChip(headliner.item.label, size: 13).fixedSize()
                if !large { Spacer(minLength: 6) }
                Text(chamberLabel)
                    .scaledFont(11, weight: .bold)
                    .tracking(1)
                    .foregroundStyle(headliner.chamber == .senate ? Palette.chamberSenate : Palette.chamberHouse)
                    .multilineTextAlignment(large ? .leading : .trailing)
            }
            Text(headliner.headline.uppercased())
                .font(Typography.display(25, weight: .blackItalic))
                // Capped so a long word never breaks mid-word.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if let context = headliner.context {
                Text(context)
                    .scaledFont(12.5)
                    .lineSpacing(2)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            if !headliner.chips.isEmpty {
                // Chips wrap across at the usual sizes; at the largest each takes the width, so its words wrap.
                let chips = large
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(FlowLayout(spacing: 6))
                chips {
                    ForEach(headliner.chips, id: \.self) { chip in
                        Text(chip)
                            .scaledFont(12.5, weight: .semibold)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            // A radius under half the chip's height (lesson 68).
                            .background(Palette.chip, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.cardBorder, lineWidth: 1))
                    }
                }
                .padding(.top, 11)
            }
        }
        .padding(16)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(headliner.followed ? Palette.threshold : Palette.topic(headliner.group))
                .frame(height: 4)
        }
        .heroCard(cornerRadius: 22, fill: Palette.card)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var chamberLabel: String {
        headliner.chamber == .senate ? "SENATE · IN DEBATE" : "HOUSE · FULL DEBATE"
    }

    private var spoken: String {
        var parts = [headliner.item.label, chamberLabel.capitalized, headliner.headline]
        if let context = headliner.context { parts.append(context) }
        if headliner.followed { parts.append("You follow this") }
        parts += headliner.chips
        return parts.joined(separator: ". ")
    }
}

/// Senate next: `TODAY` (or the weekday), the convene time big, then the Digest's heading and the
/// program's first sentence.
struct SenateNextCard: View {
    let meeting: SenateMeeting
    let today: String

    var body: some View {
        let clock = WeekPlan.meetingClock(meeting, today: today)
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 1) {
                Text(clock.day).scaledFont(11, weight: .bold).tracking(1).foregroundStyle(Palette.textMuted)
                if let time = clock.time {
                    Text(time).font(Typography.display(26, weight: .blackItalic)).foregroundStyle(Palette.text)
                        .lineLimit(1).fixedSize()
                }
                if let half = clock.half {
                    Text(half).scaledFont(11, weight: .bold).tracking(1).foregroundStyle(Palette.textMuted)
                }
            }
            .frame(minWidth: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.heading ?? WeekSenateView.convenes(meeting))
                    .scaledFont(14.5, weight: .bold)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .scaledFont(13)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        if meeting.proForma { return "Pro forma session: the Senate meets for seconds and does no business." }
        if let program = meeting.program { return WeekPlan.sentences(program).first ?? program }
        return "The program comes out with the Congressional Record, usually the morning after the Senate adjourns."
    }
}

/// A fast-track tile: the count in the topic's colour and the family's name.
struct FastTrackTileView: View {
    let tile: FastTrackTile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(tile.count)")
                .font(Typography.display(26, weight: .blackItalic))
                .foregroundStyle(Palette.topicText(tile.group))
            Text(tile.group.name)
                .scaledFont(12)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.group.name), \(tile.count) bill\(tile.count == 1 ? "" : "s")")
        .accessibilityHint("Lists them")
    }
}

/// A row that opens its bill when it has one.
struct WeekRowButton: View {
    let row: WeekSort.Row
    let onOpenBill: (String) -> Void

    var body: some View {
        if let id = row.item.billId {
            Button { onOpenBill(id) } label: { WeekRow(row: row) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the bill")
        } else {
            WeekRow(row: row)
        }
    }
}

/// An empty state: why a side is empty, never a blank list.
struct WeekPlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title.uppercased())
                .font(Typography.display(18, weight: .blackItalic))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(message)
                .scaledFont(11.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pushed screens

/// "Program ›": the Senate's week as round 11 drew it — each meeting, the Daily Digest's program
/// verbatim with the measures it names linked, and the measures named.
public struct WeekSenateView: View {
    @Bindable var model: WeekModel
    let onOpenBill: (String) -> Void

    public init(model: WeekModel, onOpenBill: @escaping (String) -> Void) {
        self.model = model
        self.onOpenBill = onOpenBill
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("SENATE").font(Typography.pageTitle).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                if case let .loaded(schedule) = model.phase {
                    Text(schedule.weekRange).scaledFont(12, weight: .semibold).foregroundStyle(Palette.textMuted)
                    senate(schedule)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groundGlow()
        // A measure named in the Senate's program is a `floor://bill/<id>` link in the text.
        .environment(\.openURL, OpenURLAction { url in
            if case let .bill(id) = FloorLink(url: url) {
                onOpenBill(id)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func senate(_ schedule: Schedule) -> some View {
        if let senate = schedule.senate, !senate.meetings.isEmpty {
            ForEach(senate.meetings, id: \.date) { meeting in
                meetingView(meeting, items: senate.items)
            }
            if !senate.items.isEmpty {
                Text("MEASURES NAMED")
                    .font(Typography.label(11.5)).tracking(1.2).foregroundStyle(Palette.threshold)
                    .padding(.horizontal, 2).padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(WeekSort.groups(senate.items, state: model.follows.state).flatMap(\.rows)) { row in
                    WeekRowButton(row: row, onOpenBill: onOpenBill)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("The Senate plans a day at a time: it posts the next day's plan when it adjourns, so this side fills in through the week.")
                Text(senateSource(senate))
            }
            .scaledFont(10.5, weight: .medium)
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 4)
        } else {
            WeekPlaceholder(
                title: "No Senate meeting posted",
                message: schedule.senateReason ?? "The Senate hasn't named a meeting in this week."
            )
            .padding(.top, 14)
        }
    }

    private func senateSource(_ senate: Schedule.Senate) -> String {
        let issues = senate.meetings.compactMap(\.recordIssue)
        return "Source: senate.gov and the Congressional Record's Daily Digest" + (issues.isEmpty ? "" : " (\(issues.joined(separator: ", ")))")
    }

    private func meetingView(_ meeting: SenateMeeting, items: [ScheduleItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("NEXT MEETING")
                .font(Typography.label(11.5)).tracking(1.2).foregroundStyle(Palette.threshold)
                .padding(.horizontal, 2).padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.convenes(meeting))
                    .scaledFont(13, weight: .bold)
                    .foregroundStyle(Palette.text)
                if meeting.proForma {
                    Text("Pro forma session: the Senate meets for seconds and does no business.")
                        .scaledFont(10.5, weight: .medium)
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
            .accessibilityElement(children: .combine)
            if !meeting.proForma {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PROGRAM · DAILY DIGEST")
                        .font(Typography.label(11)).tracking(1.1).foregroundStyle(Palette.textMuted)
                    if let program = meeting.program {
                        Text(Self.linked(program, items: items))
                            .scaledFont(12.5)
                            .foregroundStyle(Palette.text)
                            .tint(Palette.threshold)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The program comes out with the Congressional Record, usually the morning after the Senate adjourns.")
                            .scaledFont(12)
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 12)
            }
        }
    }

    /// `Convenes Monday, 3:00 PM`, in Washington's time; the Digest's heading when senate.gov gave no time.
    static func convenes(_ meeting: SenateMeeting) -> String {
        if let at = meeting.convenesAt.flatMap(Formats.instant) {
            let style = Date.FormatStyle(timeZone: WeekPlan.washington).weekday(.wide).hour().minute()
            return "Convenes \(at.formatted(style)) ET"
        }
        if let heading = meeting.heading { return "Convenes \(heading)" }
        return "Meets \(Formats.dayText(meeting.date) ?? meeting.date)"
    }

    /// The program verbatim, each measure it names that Floor has a page for made a link.
    static func linked(_ program: String, items: [ScheduleItem]) -> AttributedString {
        var text = AttributedString(program)
        for item in items {
            guard let id = item.billId else { continue }
            let url = FloorLink.bill(id: id).url
            var searchRange = text.startIndex..<text.endIndex
            while let found = text[searchRange].range(of: item.label) {
                text[found].link = url
                text[found].underlineStyle = .single
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return text
    }
}

/// A fast-track tile's rows on their own screen, or with no family every fast-track row.
public struct FastTrackView: View {
    @Bindable var model: WeekModel
    let group: TopicGroup?
    let onOpenBill: (String) -> Void

    public init(model: WeekModel, group: TopicGroup?, onOpenBill: @escaping (String) -> Void) {
        self.model = model
        self.group = group
        self.onOpenBill = onOpenBill
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text((group?.name ?? "Fast track").uppercased())
                    .font(Typography.pageTitle)
                    .foregroundStyle(group.map(Palette.topicText) ?? Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("House bills that need two-thirds and usually pass without debate.")
                    .scaledFont(12.5)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                if case let .loaded(schedule) = model.phase {
                    ForEach(WeekPlan.rows(WeekPlan.fastTrack(schedule, state: model.follows.state), in: group)) { row in
                        WeekRowButton(row: row, onOpenBill: onOpenBill)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groundGlow()
    }
}

/// One item on a week's list (the mock's `.wk`): citation, a FOLLOWING tag, the title, the latest
/// step; a gold leading edge when you follow it.
struct WeekRow: View {
    let row: WeekSort.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.item.label.uppercased())
                    .font(Typography.label(12))
                    .tracking(0.8)
                    .foregroundStyle(Palette.threshold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if row.pulled {
                    Text("OFF THE LIST").font(Typography.label(10)).tracking(0.8).foregroundStyle(Palette.textMuted)
                } else if let tag {
                    Text(tag).font(Typography.label(10)).tracking(0.8).foregroundStyle(Palette.threshold).lineLimit(1)
                }
            }
            Text(row.item.title)
                .scaledFont(13, weight: .bold)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let latest = row.item.latestLine {
                Text(latest)
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if row.followed != nil, !row.pulled {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(Palette.threshold).frame(width: 3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
        .opacity(row.pulled ? 0.6 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// `FOLLOWING · LABOR`: the topic's first word, as the mock shortens it; `FOLLOWING` for a bill.
    private var tag: String? {
        switch row.followed {
        case .bill: "FOLLOWING"
        case let .topic(name): "FOLLOWING · \(name.split(separator: " ").first.map(String.init)?.uppercased() ?? name.uppercased())"
        case nil: nil
        }
    }

    private var spoken: String {
        var parts = [row.item.label, row.item.title]
        switch row.followed {
        case .bill: parts.append("You follow this bill")
        case let .topic(name): parts.append("In \(name), a topic you follow")
        case nil: break
        }
        if row.pulled { parts.append("Taken off this week's list") }
        if let latest = row.item.latestLine { parts.append("Latest: \(latest)") }
        return parts.joined(separator: ". ")
    }
}
