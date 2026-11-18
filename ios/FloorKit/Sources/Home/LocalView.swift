import DesignSystem
import Models
import SwiftUI

/// The Local tab (v0.2.60, State & city option A of https://claude.ai/artifact/Lz7DMYwAUMLCzUQwuupFKW):
/// LOCAL with "Cities ›", a switch over your hubs (your state, then your cities), and the hub.
///
/// A state hub: SIGNED INTO LAW, WAITING ON THE GOVERNOR, IN THE NEWS, YOUR STATE LEGISLATORS. A
/// city hub: PASSED, with the Finals-style score where the record has a tally, then IN THE NEWS.
/// There is no council-member row: the Census has no council districts to match an address to.
/// Empty sections are left out.
public struct LocalView: View {
    let model: LocalModel
    let onOpenCities: () -> Void
    /// No district: the existing address flow.
    let onFindReps: () -> Void
    /// A district stored before v0.2.60: look the address up again for the state districts.
    let onChangeAddress: () -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    public init(model: LocalModel, onOpenCities: @escaping () -> Void, onFindReps: @escaping () -> Void,
                onChangeAddress: @escaping () -> Void) {
        self.model = model
        self.onOpenCities = onOpenCities
        self.onFindReps = onFindReps
        self.onChangeAddress = onChangeAddress
    }

    private var readerCalendar: Calendar {
        var c = calendar
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await model.loadList()
            if let id = model.current { await model.loadHub(id) }
        }
        .groundGlow()
        .opensLinksInSafariView()
        .task { await model.loadList() }
        .task(id: model.current) {
            guard let id = model.current, model.needsRefresh(id) else { return }
            await model.loadHub(id)
        }
        .task { await model.loadLegislators() }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("LOCAL")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onOpenCities) {
                Text("Cities ›")
                    .scaledFont(Typography.Local.cities, weight: .semibold)
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cities")
            .accessibilityHint("Add or remove cities")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.district == nil {
            DashedNote(LocalText.noState, action: (LocalText.lookUp, onFindReps))
        } else if model.hubIds.isEmpty {
            if case let .failed(message) = model.listPhase {
                BlockLine(text: message) { Task { await model.loadList() } }
            } else {
                DashedNote(LocalText.noStateHub(model.district.map { StateName.full($0.state) } ?? ""))
            }
        } else {
            HubSwitch(model: model)
            if let id = model.current { hub(id) }
        }
    }

    @ViewBuilder
    private func hub(_ id: String) -> some View {
        switch model.hub(id) {
        case .loading:
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
        case let .failed(message):
            BlockLine(text: message) { Task { await model.loadHub(id) } }
        case let .loaded(hub):
            if let saved = model.saved[id] { SavedDataNote(saved) }
            if hub.jurisdiction.kind == .state { stateHub(hub) } else { cityHub(hub) }
        }
    }

    // MARK: State

    @ViewBuilder
    private func stateHub(_ hub: LocalHub) -> some View {
        if hub.isEmpty {
            BlockLine(text: LocalText.nothing(hub.jurisdiction.name))
        }
        if !hub.enacted.isEmpty {
            sectionTitle("Signed into law")
            ForEach(hub.enacted) { LocalItemCard(item: $0) }
        }
        if !hub.waiting.isEmpty {
            sectionTitle("Waiting on the governor")
            ForEach(hub.waiting) { WaitingRow(item: $0) }
        }
        news(hub)
        legislators(hub.jurisdiction.state)
    }

    @ViewBuilder
    private func legislators(_ state: String) -> some View {
        if !model.hasStateDistricts {
            sectionTitle("Your state legislators")
            DashedNote(LocalText.needDistricts(state: state), action: (LocalText.lookUpAgain, onChangeAddress))
        } else if !model.legislators.isEmpty {
            sectionTitle("Your state legislators")
            VStack(spacing: 0) {
                ForEach(Array(model.legislators.enumerated()), id: \.element.id) { index, person in
                    LegislatorRow(legislator: person, state: state, rule: index > 0)
                }
            }
        }
    }

    // MARK: City

    @ViewBuilder
    private func cityHub(_ hub: LocalHub) -> some View {
        if let note = LocalText.coverage(hub.jurisdiction) {
            Text(note)
                .scaledFont(Typography.Local.note)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .panel(padding: 13)
        }
        if hub.isEmpty {
            BlockLine(text: LocalText.nothing(hub.jurisdiction.name))
        }
        if !hub.enacted.isEmpty {
            sectionTitle("Passed")
            ForEach(hub.enacted) { LocalItemCard(item: $0) }
        }
        news(hub)
    }

    @ViewBuilder
    private func news(_ hub: LocalHub) -> some View {
        if !hub.news.isEmpty {
            sectionTitle("In the news")
            VStack(spacing: 0) {
                ForEach(Array(hub.news.enumerated()), id: \.element.id) { index, headline in
                    HeadlineRow(headline, calendar: readerCalendar, rule: index > 0)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.blockTitle)
            .foregroundStyle(Palette.text)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 10)
    }
}

/// The segmented row of hubs (`.scope`): equal widths, the current one white.
struct HubSwitch: View {
    let model: LocalModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            ForEach(model.hubIds, id: \.self) { id in
                let on = id == model.current
                Button { model.selected = id } label: {
                    Text(model.name(id))
                        .scaledFont(Typography.Local.hub, weight: .bold)
                        .foregroundStyle(on ? Palette.verdictInk : Palette.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .background(on ? Palette.verdict : Palette.chip, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Color.clear : Palette.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }
}

/// A law signed, or a council matter passed (`.glass.hero.big1`): the cite chip and the date, the
/// title, then the summary in two lines — or, with a tally, the Finals-style score.
struct LocalItemCard: View {
    let item: LocalItem
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { if let url = item.link { openURL(url) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    SkewChip(item.identifier.isEmpty ? item.body : item.identifier,
                             foreground: Palette.verdictInk, background: Palette.verdict, size: Typography.Local.chip)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text(item.shortDate.uppercased())
                        .scaledFont(Typography.Local.date, weight: .bold)
                        .tracking(1)
                        .foregroundStyle(Palette.textMuted)
                }
                Text(item.title.uppercased())
                    .font(Typography.Local.itemTitle)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                if let tally = item.tally {
                    score(tally).padding(.top, 12)
                }
                if let summary = item.summary {
                    Text(summary)
                        .scaledFont(Typography.Local.summary)
                        .foregroundStyle(Palette.textSecondary)
                        .lineSpacing(2)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .heroCard(cornerRadius: 22, fill: Palette.panel)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalText.spoken(item))
        .accessibilityHint(item.link == nil ? "" : "Opens the record")
    }

    /// YES n · PASSED · NO n.
    private func score(_ tally: (yes: Int, no: Int)) -> some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("YES").scaledFont(Typography.Local.scoreLabel, weight: .bold).tracking(1).foregroundStyle(Palette.yea)
                Text("\(tally.yes)").font(Typography.Local.score).monospacedDigit().foregroundStyle(Palette.yea)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                SkewChip("PASSED", foreground: Palette.ground, background: Palette.yea, size: Typography.Local.stamp).fixedSize()
                Text("FINAL").scaledFont(Typography.Local.scoreLabel, weight: .bold).tracking(1).foregroundStyle(Palette.textMuted)
                    .fixedSize()
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("NO").scaledFont(Typography.Local.scoreLabel, weight: .bold).tracking(1).foregroundStyle(Palette.nay)
                Text("\(tally.no)").font(Typography.Local.score).monospacedDigit().foregroundStyle(Palette.nay)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A bill on the governor's desk (`.glass`): the title, and one line of its summary or its body.
struct WaitingRow: View {
    let item: LocalItem
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { if let url = item.link { openURL(url) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .scaledFont(Typography.Local.rowTitle, weight: .bold)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.summary ?? item.body)
                    .scaledFont(Typography.Local.rowLine)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.summary ?? item.body].joined(separator: ". "))
        .accessibilityHint(item.link == nil ? "" : "Opens the record")
    }
}

/// One of your state legislators: the photo or initials, the name, the party letter in its colour,
/// and the seat.
struct LegislatorRow: View {
    let legislator: StateLegislator
    let state: String
    let rule: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        let seat = StateChambers.seat(legislator, state: state)
        Button { if let url = legislator.url.flatMap(URL.init(string:)) { openURL(url) } } label: {
            HStack(spacing: 11) {
                portrait
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(legislator.name)
                            .scaledFont(Typography.Local.legislatorName, weight: .bold)
                            .foregroundStyle(Palette.text)
                        if !legislator.partyLetter.isEmpty {
                            Text(legislator.partyLetter)
                                .scaledFont(Typography.Local.legislatorName, weight: .heavy)
                                .foregroundStyle(Palette.party(legislator.partyLetter))
                        }
                    }
                    Text(seat)
                        .scaledFont(Typography.Local.legislatorSeat)
                        .foregroundStyle(Palette.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .overlay(alignment: .top) { if rule { Rectangle().fill(Palette.cardBorder).frame(height: 1) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(legislator.name), \(legislator.party), \(seat)")
    }

    private var portrait: some View {
        let initials = Text(legislator.initials)
            .scaledFont(Typography.Local.badge, weight: .bold)
            .foregroundStyle(Palette.text)
            .frame(width: 36, height: 36)
            .background(Palette.partyTint(legislator.partyLetter), in: .circle)
        return Group {
            if let url = legislator.photoUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase { image.resizable().scaledToFill() } else { initials }
                }
                .frame(width: 36, height: 36)
                .clipShape(.circle)
            } else {
                initials
            }
        }
        .accessibilityHidden(true)
    }
}

/// A line where a section has nothing, with Try again after a failed load.
struct BlockLine: View {
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .scaledFont(Typography.Local.note)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again", action: retry)
                    .scaledFont(Typography.Local.button, weight: .semibold)
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every city Floor covers, with how much of it, and an add/remove toggle. Your state is not
/// listed: it is automatic.
public struct CitiesView: View {
    let model: LocalModel

    public init(model: LocalModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("CITIES")
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
                Text(LocalText.citiesLine)
                    .scaledFont(Typography.Local.note)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                if case let .failed(message) = model.listPhase, model.registry.cities.isEmpty {
                    BlockLine(text: message) { Task { await model.loadList() } }
                }
                ForEach(model.registry.cities) { city in
                    CityRow(city: city, saved: model.isSaved(city)) { model.toggle(city) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.ground)
        .task { if model.registry.jurisdictions.isEmpty { await model.loadList() } }
    }
}

struct CityRow: View {
    let city: Jurisdiction
    let saved: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(city.name)
                        .scaledFont(Typography.Local.cityName, weight: .bold)
                        .foregroundStyle(Palette.text)
                    CoverageBadge(coverage: city.coverage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                    .scaledFont(Typography.Local.toggle)
                    .foregroundStyle(saved ? Palette.yea : Palette.textSecondary)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.cardBorder).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(city.name), \(LocalText.badge(city.coverage))")
        .accessibilityValue(saved ? "Added" : "Not added")
        .accessibilityHint(saved ? "Removes it from Local" : "Adds it to Local")
        .accessibilityAddTraits(saved ? [.isSelected] : [])
    }
}

/// Ready (yea tint), Coming soon (gold), News only (grey).
struct CoverageBadge: View {
    let coverage: Jurisdiction.Coverage

    var body: some View {
        let (ink, fill): (Color, Color) = switch coverage {
        case .records: (Palette.yea, Palette.yea.opacity(Palette.badgeReadyTint))
        case .pending: (Palette.threshold, Palette.threshold.opacity(Palette.badgeSoonTint))
        case .newsOnly: (Palette.textMuted, Palette.chip)
        }
        Text(LocalText.badge(coverage))
            .scaledFont(Typography.Local.badge, weight: .bold)
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(fill, in: .rect(cornerRadius: 6))
    }
}
