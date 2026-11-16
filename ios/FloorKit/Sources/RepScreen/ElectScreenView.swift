import APIClient
import DesignSystem
import Models
import SwiftUI

/// A member-elect before they take office, built to the locked members-elect mock
/// (https://claude.ai/artifact/Hod9RDLS1DgxapLeBcA3QY, section B): the member screen's Votes ·
/// Money · Contact, each saying plainly what exists yet. Where this differs from the mock, and why:
///
/// - No Follow button: following is by Bioguide ID, which most senators-elect do not have yet, and
///   following an elect id would need new follow plumbing. Once sworn in they are followed as members.
/// - Votes says nothing about the state's certification: no source for its calendar is served.
/// - Money's Funding has no "Top donors by employer" card and no post-election report date: the
///   route serves the campaign's totals only, and Floor shows no figure it does not have.
/// - The tabs are the member screen's segmented switch, not the mock's underlined tabs, so the two
///   screens read as one.
public struct ElectScreenView: View {
    @Environment(\.locale) private var locale
    @State private var model: ElectScreenModel
    @State private var section: MemberSection

    public init(model: ElectScreenModel, section: MemberSection = .record) {
        _model = State(initialValue: model)
        _section = State(initialValue: section)
    }

    public var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
        }
        .task { if model.needsRefresh { await model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 60)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).scaledFont(13).foregroundStyle(Palette.textSecondary)
                Button("Try again") { Task { await model.load() } }
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Palette.accent)
            }
            .panel()
        case .noLongerListed:
            DashedPlaceholder(
                title: "No longer listed",
                body: "Floor lists members-elect only until they take office, and this one isn't on the list now. "
                    + "Once sworn in, they're found by name in search."
            )
            .padding(.top, 20)
        case let .loaded(profile):
            if let saved = model.saved { SavedDataNote(saved) }
            hero(profile.elect)
            SectionSwitch(selection: $section)
            switch section {
            case .record: votes(profile.elect)
            case .money: money(profile)
            case .contact: contact(profile.elect)
            }
        }
    }

    // MARK: Header

    private func hero(_ elect: MemberElect) -> some View {
        let seat = elect.chamber == .senate ? StateName.full(elect.state) : elect.asMember.seatBadge
        let caption = "\(elect.title) · \(seat) · \(PartyName.singular(elect.party))"
        return HStack(spacing: 12) {
            ElectAvatar(elect, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(elect.fullName.uppercased())
                    .font(Typography.headline(30))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(caption).scaledFont(12, weight: .medium).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Votes

    private func votes(_ elect: MemberElect) -> some View {
        let elected = ElectText.electionDay(elect).flatMap { ElectText.day($0, locale: locale) }
        let seatName = ElectText.seatName(state: elect.state, district: elect.district, chamber: elect.chamber)
        let called = ElectText.calledBy(elect.call)
        // A special election's winner is sworn in once the state certifies: no date is shown.
        let title: String
        let line: String
        if elect.takesOfficeOnCertification {
            title = "Takes office when \(StateName.full(elect.state)) certifies the result"
            let seat = elect.replaces.map { "the seat \($0.fullName) holds" } ?? seatName
            line = "Won the special election\(elected.map { " on \($0)" } ?? "") for \(seat). \(called)."
        } else {
            title = "Takes office \(ElectText.day(elect.takesOffice, locale: locale) ?? elect.takesOffice)"
            let seat = elect.replaces.map { "the seat \($0.fullName) is leaving" } ?? seatName
            line = "\(elected.map { "Elected \($0)" } ?? "Elected") to \(seat). \(called)."
        }
        let congress = ElectText.congress(elect).map { " in the \(StateName.ordinal($0)) Congress" } ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(Typography.label(12))
                    .tracking(1.2)
                    .foregroundStyle(Palette.elect)
                Text(line).scaledFont(11, weight: .medium).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = elect.call.sourceUrl.flatMap(URL.init(string:)) {
                    source(url, text: "Source · \(url.host?.replacingOccurrences(of: "www.", with: "") ?? "the call")")
                        .padding(.horizontal, -2)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.elect.opacity(Tones.electTint), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.elect.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .combine)
            DashedPlaceholder(
                title: "No votes yet",
                body: "The record starts with \(elect.lastName)'s first roll call\(congress)."
            )
        }
    }

    // MARK: Money

    @ViewBuilder
    private func money(_ profile: ElectProfile) -> some View {
        @Bindable var model = model
        SectionSwitch(selection: $model.moneySegment, label: "Money")
        if model.moneySegment == .funding {
            funding(profile)
        } else {
            disclosure(profile)
        }
    }

    private func dollars(_ x: Double) -> String {
        x.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(locale))
    }

    private func fecLink(_ profile: ElectProfile) -> (URL, String)? {
        if let id = profile.elect.fecCandidateId, let url = URL(string: "https://www.fec.gov/data/candidate/\(id)/") {
            return (url, "FEC candidate \(id)")
        }
        return profile.funding?.sourceUrl.flatMap(URL.init(string:)).map { ($0, "The FEC's filings") }
    }

    @ViewBuilder
    private func funding(_ profile: ElectProfile) -> some View {
        if let funding = profile.funding, let raised = funding.receipts {
            VStack(alignment: .leading, spacing: 7) {
                label("\(funding.cycle.map { "\($0) campaign" } ?? "Campaign") · FEC")
                HStack(spacing: 6) {
                    figure("Raised", MoneyFormat.total(raised), spoken: MoneyFormat.spoken(raised))
                    figure("Spent", funding.disbursements.map(MoneyFormat.total) ?? "—",
                           spoken: funding.disbursements.map(MoneyFormat.spoken) ?? "not reported")
                }
                Text(fundingLine(funding, raised: raised))
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                if let (url, text) = fecLink(profile) { source(url, text: text) }
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                DashedPlaceholder(
                    title: "No FEC totals yet",
                    body: "Floor has no campaign totals from the FEC for \(profile.elect.fullName) yet. They show here once it does."
                )
                if let (url, text) = fecLink(profile) { source(url, text: text) }
            }
        }
    }

    /// `$53,830,872 raised and $51,096,843 spent, through Oct 14, 2026, as the campaign reported them.`
    private func fundingLine(_ funding: ElectFunding, raised: Double) -> String {
        var line = "\(dollars(raised)) raised"
        if let spent = funding.disbursements { line += " and \(dollars(spent)) spent" }
        if let end = funding.coverageEnd.flatMap({ ElectText.day($0, locale: locale) }) { line += ", through \(end)" }
        return line + ", as the campaign reported them to the FEC. Later reports update it."
    }

    private func figure(_ title: String, _ value: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(Typography.label(10.5)).tracking(1).foregroundStyle(Palette.textMuted)
            Text(value).font(Typography.display(21, weight: .blackItalic)).foregroundStyle(Palette.text)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(spoken)")
    }

    @ViewBuilder
    private func disclosure(_ profile: ElectProfile) -> some View {
        if let report = profile.disclosure {
            VStack(alignment: .leading, spacing: 7) {
                label("Assets · candidate report")
                if report.assets.isEmpty {
                    Text(report.paper ? "Filed on paper, so Floor links the report rather than reading it." : "The report lists no assets.")
                        .scaledFont(12).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
                ForEach(Array(report.assets.enumerated()), id: \.offset) { _, asset in
                    DisclosuresFigures.range(
                        title: asset.name, value: asset.value,
                        detail: [asset.type, DisclosuresFigures.owner(asset.owner), asset.account].compactMap(\.self)
                            .joined(separator: " · ")
                    )
                }
                Text("Candidates file the same report members do, before the election. Ranges as filed; Floor doesn't estimate a total.")
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                if let url = report.sourceUrl.flatMap(URL.init(string:)) {
                    let filed = report.filedAt.flatMap(DisclosuresFigures.day).map { "Filed \($0) · " } ?? ""
                    source(url, text: "\(filed)Open the report")
                }
            }
        } else {
            DashedPlaceholder(
                title: "No candidate report in Floor yet",
                body: "Candidates file a financial disclosure report before the election. When Floor has \(profile.elect.lastName)'s, "
                    + "its ranges show here as filed, never a total."
            )
        }
    }

    // MARK: Contact

    private func contact(_ elect: MemberElect) -> some View {
        let certifies = elect.takesOfficeOnCertification
        let when = certifies
            ? ", once \(StateName.full(elect.state)) certifies the result"
            : " on \(ElectText.day(elect.takesOffice, locale: locale) ?? elect.takesOffice)"
        let holder = elect.replaces.map {
            " \($0.fullName) holds the seat until \(certifies ? "then" : ElectText.takesOffice(elect, locale: locale))."
        } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            DashedPlaceholder(
                title: elect.chamber == .senate ? "No Senate office yet" : "No House office yet",
                body: "A Washington phone, contact form and website are assigned at the swearing-in\(when). Floor adds them that day."
            )
            Text("Until then, Speak up doesn't offer \(elect.lastName): offices count messages from constituents of sitting members.\(holder)")
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    // MARK: Pieces

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.label(10.5))
            .tracking(1.0)
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func source(_ url: URL, text: String) -> some View {
        Link(destination: url) {
            Text(text + " ›").scaledFont(11.5, weight: .semibold).foregroundStyle(Palette.yea)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 2)
    }
}
