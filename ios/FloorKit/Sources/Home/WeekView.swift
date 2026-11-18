import DesignSystem
import Models
import Onboarding
import SwiftUI

/// The Week tab, built to round 11's section A (<https://claude.ai/artifact/VdSGbow4qnJwYe2sV7Tb2r>).
///
/// House: the Majority Leader's list split the way the House splits it, what you follow first with
/// the gold edge. Senate: when it next meets and the Daily Digest's program in its own words, with
/// the measures it names linked. An empty side says why, never a blank list; and it never says the
/// House is in recess, because an unpublished week is not reported as one.
///
/// Where this differs from the mock, and why:
/// - The Senate side shows the Digest's program verbatim rather than the mock's "Expected votes"
///   rows: the mock's Senate rows were marked illustrative, and the program is the real source.
/// - Week arrows in the header: the ingest keeps this week and next, so next week is one tap away.
/// - Items taken off the list stay at the end of their group, dimmed, marked "Off the list".
public struct WeekView: View {
    @Bindable var model: WeekModel
    let onOpenBill: (String) -> Void

    public init(model: WeekModel, onOpenBill: @escaping (String) -> Void) {
        self.model = model
        self.onOpenBill = onOpenBill
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
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
                    segment(schedule)
                    if model.chamber == .house { house(schedule) } else { senate(schedule) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groundGlow()
        .refreshable { await model.load() }
        .task { if model.needsRefresh { await model.load() } }
        // A measure named in the Senate's program is a `floor://bill/<id>` link in the text.
        .environment(\.openURL, OpenURLAction { url in
            if case let .bill(id) = FloorLink(url: url) {
                onOpenBill(id)
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.offset == 0 ? "THIS WEEK" : model.offset == 1 ? "NEXT WEEK" : "WEEK OF")
                .font(Typography.headline(28))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                arrow("chevron.left", to: model.offset - 1, label: "Previous week")
                Text(range)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                arrow("chevron.right", to: model.offset + 1, label: "Next week")
            }
        }
        .padding(.bottom, 4)
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

    private func segment(_ schedule: Schedule) -> some View {
        let listed = schedule.house.items.filter { $0.removedAt == nil }.count
        return HStack(spacing: 4) {
            ForEach([Chamber.house, .senate], id: \.self) { chamber in
                let on = model.chamber == chamber
                let title = chamber == .house && listed > 0 ? "HOUSE · \(listed)" : chamber.name.uppercased()
                Button { model.chamber = chamber } label: {
                    Text(title)
                        .font(Typography.label(12))
                        .tracking(0.6)
                        .lineLimit(1)
                        .foregroundStyle(on ? Palette.text : Palette.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? Palette.chip : Color.clear, in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chamber == .house ? "House, \(listed) listed" : "Senate")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.panel, in: .rect(cornerRadius: 9))
    }

    // MARK: House

    @ViewBuilder
    private func house(_ schedule: Schedule) -> some View {
        let groups = model.groups(schedule)
        if schedule.house.inSession != true || groups.isEmpty {
            placeholder(
                title: "No floor schedule posted",
                body: "No floor schedule posted for this week. The House lists each week's bills ahead of time, and they show here once it does."
            )
            .padding(.top, 14)
            placeholder(
                title: "Nothing you follow is scheduled",
                body: "Follow a bill or a topic and it shows here the week it reaches the floor, and you can get an alert."
            )
        } else {
            ForEach(groups) { group in
                groupView(group)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceLine(schedule))
                Text("Listed means it may come up: the House adds and drops items through the week.")
            }
            .scaledFont(10.5, weight: .medium)
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 4)
        }
    }

    private func sourceLine(_ schedule: Schedule) -> String {
        let updated = schedule.sourceUpdatedAt.flatMap(Formats.instant).map {
            $0.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "America/New_York")!).month(.abbreviated).day())
        }
        return ["Source: House Majority Leader", updated.map { "updated \($0)" }].compactMap(\.self).joined(separator: ", ")
    }

    private func groupView(_ group: WeekSort.Group) -> some View {
        let open = model.expanded.contains(group.category)
        let shown = open ? group.rows.count : min(group.rows.count, WeekSort.visibleCount(group))
        let hidden = group.rows.count - shown
        return VStack(alignment: .leading, spacing: 7) {
            Text("\(group.title) · \(group.count)".uppercased())
                .font(Typography.label(11.5))
                .tracking(1.2)
                .foregroundStyle(Palette.threshold)
                .padding(.horizontal, 2)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.rows.prefix(shown)) { row in
                if let id = row.item.billId {
                    Button { onOpenBill(id) } label: { WeekRow(row: row) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the bill")
                } else {
                    WeekRow(row: row)
                }
            }
            if hidden > 0 {
                Button { model.expanded.insert(group.category) } label: {
                    Text("+ \(hidden) more")
                        .scaledFont(11.5, weight: .semibold)
                        .foregroundStyle(Palette.threshold)
                        .padding(.horizontal, 2)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(hidden) more \(group.title.lowercased())")
            }
        }
    }

    // MARK: Senate

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
                    if let id = row.item.billId {
                        Button { onOpenBill(id) } label: { WeekRow(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the bill")
                    } else {
                        WeekRow(row: row)
                    }
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
            placeholder(
                title: "No Senate meeting posted",
                body: schedule.senateReason ?? "The Senate hasn't named a meeting in this week."
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
            let style = Date.FormatStyle(timeZone: TimeZone(identifier: "America/New_York")!).weekday(.wide).hour().minute()
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

    // MARK: Pieces

    private func placeholder(title: String, body: String) -> some View {
        VStack(spacing: 5) {
            Text(title.uppercased())
                .font(Typography.display(18, weight: .blackItalic))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(body)
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
