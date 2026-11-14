import APIClient
import AppIntents
import DesignSystem
import Foundation
import Models
import Onboarding
import SwiftUI
import WidgetFeed
import WidgetKit

// The two home-screen widgets from the locked design, section "D · Widgets" of
// https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn, and the medium widget's member pick from the
// Following design, section C of https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre. What they show
// is built and tested in FloorKit's `WidgetFeed`; this target is WidgetKit and drawing only.

@main
struct FloorWidgetBundle: WidgetBundle {
    var body: some Widget {
        LatestFinalWidget()
        MembersWidget()
        VoteLiveActivity()
    }
}

/// Small: the newest final vote any of your members took part in — your reps and everyone you follow.
struct LatestFinalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.floor.widget.latest-final", provider: FloorTimeline()) { entry in
            LatestFinalView(entry: entry)
        }
        .configurationDisplayName("Latest final")
        .description("The last final vote in your members' records, and how one of them voted.")
        .supportedFamilies([.systemSmall])
    }
}

/// Medium: up to three of your members' most recent votes, picked in the widget's Edit menu; your
/// reps until you pick. The kind is the one "Your three" shipped with, so a widget already on a home
/// screen carries over (as your reps) instead of disappearing.
struct MembersWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.floor.widget.your-three", intent: PickMembersIntent.self, provider: MembersTimeline()) { entry in
            MembersView(entry: entry)
        }
        .configurationDisplayName("Your members")
        .description("How up to three of your members voted most recently. Pick them with Edit Widget; until then, your reps.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - The member pick

/// A member to pick for the medium widget: one of your reps or someone you follow.
struct MemberEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Member"
    static let defaultQuery = YourMembersQuery()

    let id: String
    let name: String
    /// `D · House · TX-37`.
    let seat: String

    init(_ member: Member) {
        id = member.bioguideId
        name = member.fullName
        seat = "\(member.party) · \(member.seatCaption)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(seat)")
    }
}

/// The members the pick offers: your reps and everyone you follow, as the app left them in the
/// App Group. Nothing else — the widget is about your members.
struct YourMembersQuery: EntityQuery {
    func entities(for identifiers: [MemberEntity.ID]) async throws -> [MemberEntity] {
        let all = Self.members()
        return identifiers.compactMap { id in all.first { $0.bioguideId == id }.map(MemberEntity.init) }
    }

    func suggestedEntities() async throws -> [MemberEntity] {
        Self.members().map(MemberEntity.init)
    }

    static func members() -> [Member] {
        UserDefaultsDelegationStore.groupDefaults().map { WidgetMembers.read(from: $0).all } ?? []
    }
}

/// The medium widget's Edit menu. Nothing picked means your reps, which is what the widget showed
/// before you could pick.
struct PickMembersIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Your members"
    static let description = IntentDescription("Choose up to three members to show. Leave it empty for your reps.")

    @Parameter(title: "Members", size: 3)
    var members: [MemberEntity]?

    init() {}
}

// MARK: - Timeline

struct FloorEntry: TimelineEntry {
    enum Content {
        /// No district and nobody followed in the app yet.
        case noMembers
        case loaded(WidgetSnapshot)
        /// The refresh failed and there is no saved copy for these members.
        case failed
    }

    var date: Date
    var content: Content
    /// The medium widget's pick, by Bioguide ID; nil for its default (your reps). The small widget
    /// has no pick.
    var chosen: [String]? = nil

    /// `As of 3:40 PM` once the votes shown are more than two hours old, else nil.
    var asOf: String? {
        guard case let .loaded(snapshot) = content else { return nil }
        return WidgetText.asOf(snapshot.fetchedAt, now: date)
    }
}

struct FloorTimeline: TimelineProvider {
    func placeholder(in context: Context) -> FloorEntry {
        FloorEntry(date: Date(), content: .loaded(.sample))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FloorEntry) -> Void) {
        // The gallery shows real TX-37 data rather than waiting on the network.
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        // `context` isn't Sendable, so the fallback is built here rather than inside the task.
        let fallback = placeholder(in: context)
        Task { completion(await Self.timeline().entries.first ?? fallback) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FloorEntry>) -> Void) {
        Task { completion(await Self.timeline()) }
    }

    /// One refresh through `WidgetFeed.refresh`, which reads your district and who you follow from
    /// the App Group before and after fetching. Loaded content gets a second entry for the moment it
    /// turns two hours old, so "As of …" appears even if WidgetKit is slow to refresh again.
    /// - Parameter medium: the medium widget, which fetches only the rows it draws (`chosen`, or your
    ///   reps) and keeps its own saved copy; the small one fetches everyone.
    static func timeline(medium: Bool = false, chosen: [String]? = nil) async -> Timeline<FloorEntry> {
        let now = Date()
        guard let group = UserDefaultsDelegationStore.groupDefaults() else {
            // No App Group in this build: the app can't share your members, so there are none to show.
            return Timeline(entries: [FloorEntry(date: now, content: .noMembers)], policy: .never)
        }
        // The stores, not the suite, cross into the refresh: they are Sendable and `UserDefaults` is not.
        let delegations = UserDefaultsDelegationStore(defaults: group)
        let follows = UserDefaultsFollowStore(defaults: group)
        let result = await WidgetFeed.refresh(
            members: { WidgetMembers(delegation: delegations.load(), follows: follows.load()) },
            only: { medium ? $0.mediumIds(chosen: chosen) : nil },
            api: api,
            store: WidgetSnapshotStore(defaults: group, key: medium ? WidgetSnapshotStore.mediumKey : WidgetSnapshotStore.key),
            now: now
        )
        let content: FloorEntry.Content = switch result {
        case .noMembers: .noMembers
        case let .fresh(snapshot), let .saved(snapshot): .loaded(snapshot)
        case .failed: .failed
        }
        var entries = [FloorEntry(date: now, content: content, chosen: chosen)]
        if case let .loaded(snapshot) = content {
            let stale = snapshot.fetchedAt.addingTimeInterval(WidgetText.staleAfter + 60)
            if stale > now { entries.append(FloorEntry(date: stale, content: content, chosen: chosen)) }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(result.retryAfter)))
    }

    /// The same API as the app, from the same `FloorAPIBaseURL` build setting, on a session with a
    /// short timeout and no response cache: the app's cache lives in its own container, and the
    /// widget keeps only its last snapshot.
    static let api: FloorAPI = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "FloorAPIBaseURL") as? String
        return FloorAPI(
            baseURL: configured.flatMap(URL.init(string:)) ?? FloorAPI.localDevelopment,
            session: WidgetFeed.makeSession()
        )
    }()
}

/// The medium widget's timeline: the same refresh, carrying the members picked in Edit Widget.
struct MembersTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FloorEntry {
        FloorEntry(date: Date(), content: .loaded(.sample))
    }

    func snapshot(for configuration: PickMembersIntent, in context: Context) async -> FloorEntry {
        if context.isPreview { return placeholder(in: context) }
        let chosen = Self.chosen(configuration)
        return await FloorTimeline.timeline(medium: true, chosen: chosen).entries.first
            ?? FloorEntry(date: Date(), content: .loaded(.sample), chosen: chosen)
    }

    func timeline(for configuration: PickMembersIntent, in context: Context) async -> Timeline<FloorEntry> {
        await FloorTimeline.timeline(medium: true, chosen: Self.chosen(configuration))
    }

    static func chosen(_ configuration: PickMembersIntent) -> [String]? {
        configuration.members?.map(\.id)
    }
}

// MARK: - Small

struct LatestFinalView: View {
    var entry: FloorEntry

    var body: some View {
        Group {
            switch entry.content {
            case let .loaded(snapshot):
                if let latest = snapshot.latestFinal {
                    card(latest)
                } else {
                    Message(header: "Final", title: "No finals yet", detail: "Your members' next vote shows here.")
                        .widgetURL(FloorLink.open.url)
                }
            case .noMembers:
                Message.noMembers.widgetURL(FloorLink.open.url)
            case .failed:
                Message.failed.widgetURL(FloorLink.open.url)
            }
        }
        .containerBackground(Palette.widget, for: .widget)
    }

    private func card(_ final: WidgetSnapshot.Final) -> some View {
        let vote = final.vote
        let score = WidgetText.score(vote)
        return VStack(alignment: .leading, spacing: 7) {
            WidgetHeader(WidgetText.smallHeader(vote))
            Text(WidgetText.citation(vote, measure: final.measure).uppercased())
                .font(Typography.headline(20))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let word = WidgetText.resultWord(vote) {
                Text(word)
                    .font(Typography.label(12))
                    .tracking(1.2)
                    .foregroundStyle(vote.kind == .election ? Palette.textSecondary : Palette.outcome(vote.outcome))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                ScoreText(score: score.left)
                Spacer(minLength: 4)
                // A one-candidate Speaker ballot has no second number to show.
                if let right = score.right {
                    ScoreText(score: right, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                PositionChip(position: final.call.position, choice: final.call.choice)
                Text(final.call.member.lastName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                if let asOf = entry.asOf {
                    Spacer(minLength: 2)
                    Text(asOf)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([WidgetText.smallLabel(final), entry.asOf.map { $0 + "." }].compactMap(\.self).joined(separator: " "))
        .widgetURL(FloorLink.vote(id: vote.id).url)
    }
}

/// A big number: yea in yea green, nay in nay orange, a Speaker candidate's total in the text colour.
private struct ScoreText: View {
    var score: WidgetText.Score

    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(score.value, format: .number)
                .font(Typography.display(32, weight: .blackItalic, scales: false))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // Yea and nay say which is which by colour; two Speaker candidates need their names.
            if score.side == nil, !score.label.isEmpty {
                Text(score.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
    }

    private var color: Color {
        switch score.side {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case nil: Palette.text
        }
    }
}

// MARK: - Medium

struct MembersView: View {
    var entry: FloorEntry

    var body: some View {
        Group {
            switch entry.content {
            case let .loaded(snapshot):
                rows(snapshot)
            case .noMembers:
                Message.noMembers.widgetURL(FloorLink.open.url)
            case .failed:
                Message.failed.widgetURL(FloorLink.open.url)
            }
        }
        .containerBackground(Palette.widget, for: .widget)
    }

    private func rows(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetHeader(WidgetText.header(snapshot, chosen: entry.chosen), trailing: entry.asOf)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(snapshot.mediumRows(chosen: entry.chosen)) { row in
                    GridRow {
                        cell(row) {
                            if let latest = row.latest {
                                PositionChip(position: latest.position, choice: latest.choice)
                            } else {
                                Text("—").font(Typography.label(11)).foregroundStyle(Palette.textMuted)
                            }
                        }
                        cell(row) {
                            let name = Text(row.member.lastName.uppercased())
                                .font(Typography.headline(15))
                                .foregroundStyle(Palette.text)
                            let what = Text(detail(row))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.textSecondary)
                            Text("\(name)  \(what)")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        cell(row) {
                            Text(row.latest.flatMap { WidgetText.day($0.vote) } ?? "")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let note = WidgetText.loneMemberNote(snapshot, chosen: entry.chosen) {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One spoken line per member rather than three cells each.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([WidgetText.header(snapshot, chosen: entry.chosen) + "."] + snapshot.mediumRows(chosen: entry.chosen).map(WidgetText.rowLabel)
                + [entry.asOf.map { $0 + "." }].compactMap(\.self)).joined(separator: " ")
        )
        // A tap outside a row opens the newest of the votes shown.
        .widgetURL((newest(snapshot).map { FloorLink.vote(id: $0) } ?? .open).url)
    }

    /// `H.R. 1013 · Passed 295–128`, or why there is nothing.
    private func detail(_ row: WidgetSnapshot.Row) -> String {
        if row.unavailable { return "Couldn't load their votes" }
        guard let latest = row.latest else { return "No recorded votes yet" }
        return "\(WidgetText.citation(latest.vote, measure: latest.measure)) · \(WidgetText.resultLine(latest.vote))"
    }

    /// Each cell of a row opens that row's vote.
    @ViewBuilder
    private func cell(_ row: WidgetSnapshot.Row, @ViewBuilder content: () -> some View) -> some View {
        if let latest = row.latest {
            Link(destination: FloorLink.vote(id: latest.vote.id).url) { content() }
        } else {
            content()
        }
    }

    private func newest(_ snapshot: WidgetSnapshot) -> String? {
        snapshot.mediumRows(chosen: entry.chosen).compactMap(\.latest?.vote).max { a, b in
            (a.occurredAtDate ?? .distantPast) < (b.occurredAtDate ?? .distantPast)
        }?.id
    }
}

// MARK: - Pieces

/// The glyph and the tracked-out caps line: `FINAL · HOUSE`, `YOUR MEMBERS · TX-37`.
private struct WidgetHeader: View {
    var text: String
    /// Muted text at the right edge: "As of 3:40 PM" on a stale snapshot.
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            ChamberGlyph()
                .fill(Color.white)
                .frame(width: 12, height: 11)
                .frame(width: 16, height: 16)
                .background(Palette.flapBoard, in: .rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                .accessibilityHidden(true)
            Text(text.uppercased())
                .font(Typography.label(11))
                .tracking(1.1)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let trailing {
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
    }
}

/// The YEA / NAY / DNV / PRESENT chip, or a Speaker candidate's name.
private struct PositionChip: View {
    var position: Position
    var choice: String?
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let label = Text(WidgetText.chip(position, choice: choice))
            .font(Typography.label(11))
            .tracking(0.9)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        Group {
            if renderingMode == .fullColor {
                label
                    .foregroundStyle(Palette.ground)
                    .background(fill, in: .rect(cornerRadius: 4))
            } else {
                // Accented (tinted home screen) and vibrant (StandBy, lock screen) draw every pixel
                // in one tint, so a filled chip would swallow its own text. Outline it instead.
                label
                    .foregroundStyle(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary, lineWidth: 1))
                    .widgetAccentable()
            }
        }
        .fixedSize(horizontal: position != .candidate, vertical: true)
    }

    private var fill: Color {
        switch position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present, .notVoting: Palette.textMuted
        case .candidate: Palette.text
        }
    }
}

/// Empty and error states.
private struct Message: View {
    var header: String
    var title: String
    var detail: String

    static let noMembers = Message(
        header: "Floor", title: "Open Floor to pick your members",
        detail: "Your district and who you follow stay on this phone."
    )
    static let failed = Message(
        header: "Floor", title: "Couldn't reach Floor", detail: "Trying again in a few minutes."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(header)
            Spacer(minLength: 0)
            Text(title)
                .font(Typography.headline(18))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }
}

#Preview("Small", as: .systemSmall) {
    LatestFinalWidget()
} timeline: {
    FloorEntry(date: .now, content: .loaded(.sample))
    FloorEntry(date: .now, content: .noMembers)
}

#Preview("Medium", as: .systemMedium) {
    MembersWidget()
} timeline: {
    FloorEntry(date: .now, content: .loaded(.sample))
    FloorEntry(date: .now, content: .failed)
}
