import DesignSystem
import Models
import SwiftUI

// The member screen's Contact segment and Money's Disclosures half, built to round 11
// (https://claude.ai/artifact/VdSGbow4qnJwYe2sV7Tb2r, sections C and G).

// MARK: - Contact

/// Phone, write and website for one member's office, from congress-legislators (via the record).
///
/// "Write" opens the office's own form; a House office with none gets the House's "Write Your
/// Representative" form, which checks your ZIP; a senator with none gets their website.
struct ContactContent: View {
    let record: RepScreenModel
    let member: Member?

    var body: some View {
        switch record.phase {
        case .loading:
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).scaledFont(13).foregroundStyle(Palette.textSecondary)
                Button("Try again") { Task { await record.load() } }
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Palette.accent)
            }
            .panel()
        case let .loaded(loaded):
            ContactRows(member: loaded.detail.member, contact: loaded.detail.contact)
        }
    }
}

/// The three rows and the line under them; apart from the model so snapshots can draw it alone.
struct ContactRows: View {
    let member: Member
    let contact: MemberContact?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let contact, contact.phone != nil || contact.website != nil || contact.contactForm != nil || member.chamber == .house {
                if let phone = contact.phone, let tel = SpeakUpLinks.tel(phone) {
                    callButton(phone: phone, office: contact.office, url: tel)
                }
                if let write = SpeakUpLinks.form(member: member, contact: contact) {
                    row(symbol: "square.and.pencil", title: "Write to the office", caption: writeCaption(contact),
                        url: write, label: "Write to \(member.lastName)'s office")
                }
                if let site = contact.website, let url = URL(string: site) {
                    row(symbol: "arrow.up.right", title: url.host?.replacingOccurrences(of: "www.", with: "") ?? site,
                        caption: "Official website", url: url, label: "\(member.lastName)'s official website")
                }
                if let address = contact.address, !address.isEmpty {
                    addressRow(address)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NO CONTACT DETAILS YET").font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.textMuted)
                    Text("congress-legislators lists no phone, form or website for \(member.fullName) yet.")
                        .scaledFont(12.5)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityElement(children: .combine)
            }
            Text("Offices count calls and letters from constituents. Contact details from congress-legislators, updated daily.")
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.top, 4)
        }
    }

    private func writeCaption(_ contact: MemberContact) -> String {
        if contact.contactForm != nil { return "The office's contact form" }
        return member.chamber == .house
            ? "House \"Write Your Representative\" form, checks your ZIP"
            : "No form listed, so the official website"
    }

    /// The big call button (`.callbtn`): the number and the office, in yea green.
    private func callButton(phone: String, office: String?, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phone).font(Typography.callNumber).monospacedDigit()
                    Text(office.map { "Washington office · \($0)" } ?? "Washington office")
                        .scaledFont(Typography.Member.callLine)
                        .opacity(0.9)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Palette.callInk)
            .padding(14)
            .background(Palette.yea, in: .rect(cornerRadius: 16))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Call \(member.lastName)'s Washington office, \(phone)")
        .accessibilityAddTraits(.isLink)
        .padding(.bottom, 1)
    }

    private func row(symbol: String, title: String, caption: String, url: URL, label: String) -> some View {
        Link(destination: url) { rowContent(symbol: symbol, title: title, caption: caption) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isLink)
    }

    /// The mailing address: a row to read, not a link.
    private func addressRow(_ address: String) -> some View {
        rowContent(symbol: "envelope", title: address, caption: "Mailing address")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mailing address, \(address)")
    }

    private func rowContent(symbol: String, title: String, caption: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.threshold)
                .frame(width: 28, height: 28)
                .background(Palette.chip, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).scaledFont(13, weight: .bold).foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption).scaledFont(10.5, weight: .medium).foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 12)
    }
}

/// The links Contact and Speak up share. Speak up's own copy lives in BillScreen (`SpeakUpTemplate`),
/// which this module does not depend on; the rule is the same: the office's form, else the House's
/// find-your-representative form for a House member, else the website.
enum SpeakUpLinks {
    static let houseFindYourRep = URL(string: "https://www.house.gov/representatives/find-your-representative")!

    static func form(member: Member, contact: MemberContact?) -> URL? {
        if let form = contact?.contactForm.flatMap(URL.init(string:)) { return form }
        if member.chamber == .house { return houseFindYourRep }
        return contact?.website.flatMap(URL.init(string:))
    }

    static func tel(_ phone: String) -> URL? {
        let digits = phone.filter(\.isNumber)
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}

// MARK: - Disclosures

struct DisclosuresContent: View {
    let model: DisclosuresModel
    let member: Member?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load \(member?.lastName ?? "this member")'s disclosures")
                        .scaledFont(15, weight: .semibold).foregroundStyle(Palette.text)
                    Text(message).scaledFont(13).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                }
                .panel()
            case let .loaded(disclosures):
                VStack(alignment: .leading, spacing: 10) {
                    if let saved = model.saved { SavedDataNote(saved) }
                    DisclosuresFigures(disclosures: disclosures, member: member)
                }
            }
        }
        .task { if model.needsRefresh { await model.load() } }
    }
}

/// The disclosures as filed: assets in ranges, trades with how long they took to file, paper
/// filings as links. **Never a total**: no value here is added to another (product rule "Ranges,
/// not net worth"). Off (`enabled: false`), it is the visible placeholder with the API's reason.
struct DisclosuresFigures: View {
    let disclosures: Disclosures
    let member: Member?
    /// An annual report lists dozens of assets (Doggett's 2025 report, 75); the first few show
    /// until "+ N more" is tapped.
    @State private var allAssets = false
    static let assetsShown = 8

    var body: some View {
        if disclosures.enabled {
            VStack(alignment: .leading, spacing: 7) {
                assets
                trades
                paper
                Text("From the member's own filings. Ranges as filed; Floor doesn't estimate a total. A home is listed only when it earns income.")
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, 4)
            }
        } else {
            placeholder
        }
    }

    // MARK: Off

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NOT LOADED YET").fontWeight(.bold).foregroundStyle(Palette.threshold)
                Text(disclosures.reason ?? "Financial disclosures aren't available in Floor yet.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Palette.threshold, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                Text("REPORTED ASSETS · RANGES, AS FILED")
                    .font(.caption2).tracking(0.7).foregroundStyle(Palette.textMuted)
                Text("Members report what they own and owe in value bands, and leave out a home unless it earns income. "
                    + "When this loads, Floor will show those ranges as filed, and their trades — never a "
                    + "single net-worth figure.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .panel()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: On

    @ViewBuilder
    private var assets: some View {
        if let annual = disclosures.annual {
            label(["ASSETS", annual.year.map { "\($0) ANNUAL REPORT" }, annual.amendment ? "AMENDED" : nil]
                .compactMap(\.self).joined(separator: " · "))
            if annual.transcribed { TranscribedNote() }
            if annual.assets.isEmpty {
                note("The report lists no assets.")
            }
            let shown = allAssets ? annual.assets.count : min(annual.assets.count, Self.assetsShown)
            ForEach(Array(annual.assets.prefix(shown).enumerated()), id: \.offset) { _, asset in
                Self.range(
                    title: asset.name, value: asset.value,
                    detail: [asset.type, Self.owner(asset.owner), asset.account].compactMap(\.self).joined(separator: " · ")
                )
            }
            if shown < annual.assets.count {
                Button { allAssets = true } label: {
                    Text("+ \(annual.assets.count - shown) more assets")
                        .scaledFont(11.5, weight: .semibold)
                        .foregroundStyle(Palette.threshold)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 2)
            }
            if let url = annual.sourceUrl.flatMap(URL.init(string:)) {
                source(url, text: ["Filed \(annual.filedAt.flatMap(Self.day) ?? "")", "Open the report"].filter { $0 != "Filed " }
                    .joined(separator: " · "))
            }
        } else {
            label("ASSETS")
            note("No annual report on file in Floor yet.")
        }
    }

    @ViewBuilder
    private var trades: some View {
        label("TRADES · LAST 12 MONTHS").padding(.top, 4)
        if disclosures.trades.isEmpty {
            note("No trades reported in the last 12 months.")
        }
        ForEach(Array(disclosures.trades.enumerated()), id: \.offset) { _, trade in
            // The filed name usually carries the ticker already: "Coca-Cola Company (KO)".
            let ticker = trade.ticker.flatMap { trade.asset.contains("(\($0))") ? nil : " (\($0))" } ?? ""
            let title = "\(trade.verb) · \(trade.asset)\(ticker)"
            VStack(alignment: .leading, spacing: 0) {
                Self.range(title: title, value: trade.amount, detail: tradeLine(trade), flagged: trade.pastDeadline)
            }
        }
    }

    /// `Traded Mar 3 · filed Apr 10 · 38 days`; past the deadline it says so, as a fact.
    private func tradeLine(_ trade: DisclosedTrade) -> String {
        var parts: [String] = []
        if let owner = Self.owner(trade.owner) { parts.append(owner) }
        if let traded = trade.transactedAt.flatMap(Self.day) { parts.append("Traded \(traded)") }
        if let filed = trade.filedAt.flatMap(Self.day) { parts.append("filed \(filed)") }
        if let days = trade.daysToFile {
            parts.append(trade.pastDeadline
                ? "filed \(days) days after, past the \(disclosures.deadline)-day deadline"
                : "\(days) \(days == 1 ? "day" : "days")")
        } else if trade.pastDeadline {
            parts.append("filed after the \(disclosures.deadline)-day deadline")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var paper: some View {
        if !disclosures.paperFilings.isEmpty {
            label("PAPER FILINGS").padding(.top, 4)
            ForEach(Array(disclosures.paperFilings.enumerated()), id: \.offset) { _, filing in
                let kind = filing.kind == "ptr" ? "Trade report" : "Annual report"
                let text = [kind + (filing.reportYear.map { " \($0)" } ?? ""), filing.filedAt.flatMap(Self.day).map { "filed \($0)" },
                            filing.status == "unparsed" ? "Floor couldn't read it" : "scanned, not read"]
                    .compactMap(\.self).joined(separator: " · ")
                if let url = filing.sourceUrl.flatMap(URL.init(string:)) {
                    source(url, text: text)
                } else {
                    note(text)
                }
            }
        }
    }

    // MARK: Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typography.label(10.5))
            .tracking(1.0)
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text).scaledFont(12).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    /// The mock's `.rg`: what it is, its range as filed, and a line of detail. Static so a
    /// member-elect's candidate report draws its rows the same way.
    static func range(title: String, value: String?, detail: String, flagged: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).scaledFont(12, weight: .semibold).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(value ?? "Not stated").font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(12, weight: .semibold).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value ?? "Not stated").font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if !detail.isEmpty {
                Text(detail).scaledFont(10, weight: .medium).foregroundStyle(flagged ? Palette.nay : Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    private func source(_ url: URL, text: String) -> some View {
        Link(destination: url) {
            Text(text + " ›").scaledFont(11.5, weight: .semibold).foregroundStyle(Palette.yea)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 2)
    }

    /// `Spouse`, `Joint`, `Dependent child`; nil for the member's own.
    static func owner(_ owner: String?) -> String? {
        switch owner {
        case "spouse": "Spouse"
        case "joint": "Joint"
        case "dependent": "Dependent child"
        default: nil
        }
    }

    /// A calendar day (`2025-07-28`) or an instant, as `Jul 28, 2025`.
    static func day(_ string: String) -> String? {
        if let text = Formats.dayText(string) { return text }
        return Formats.instant(string)?.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The AI tag on rows Floor's AI read off a paper filing (product rule "AI is labelled and cited"):
/// the bill screen's `.lab` look, and the report link stays right under the rows.
struct TranscribedNote: View {
    static let text = "Transcribed by Floor's AI from a handwritten filing. May contain errors; check the original below."

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("AI")
                .font(Typography.label(11))
                .tracking(1.1)
                .foregroundStyle(Palette.aiInk)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Palette.ai, in: .rect(cornerRadius: 5))
                .fixedSize()
            Text(Self.text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.ai)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI. \(Self.text)")
    }
}
