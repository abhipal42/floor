import Models
import SwiftUI
#if canImport(SafariServices) && os(iOS)
import SafariServices
#endif

// v0.2.60 (https://claude.ai/artifact/Lz7DMYwAUMLCzUQwuupFKW): the pieces the News page, the member
// page's News section and the Local tab share — the tone dot and bar, a headline row, the AI READ
// chip, the dashed note, and links that open in a Safari view.

public extension Palette {
    /// A headline framing the member favourably: the yea green.
    static let toneFavorable = yea
    /// Neutral: the raised grey (the mock's `--s3`).
    static let toneNeutral = raised
    /// Critical: the nay orange.
    static let toneCritical = nay
    /// The Cities screen's badges: Ready on a yea tint, Coming soon on a gold tint, News only grey.
    static let badgeReadyTint = 0.14
    static let badgeSoonTint = 0.13

    static func tone(_ tone: NewsTone?) -> Color {
        switch tone {
        case .favorable: toneFavorable
        case .critical: toneCritical
        case .neutral, .office, nil: toneNeutral
        }
    }
}

/// The dot before a headline: filled in its tone's colour; hollow for the member's own office.
/// Nothing for a headline the AI has not read.
public struct ToneDot: View {
    let tone: NewsTone?

    public init(_ tone: NewsTone?) { self.tone = tone }

    public var body: some View {
        Group {
            if tone == .office {
                Circle().strokeBorder(Palette.textMuted, lineWidth: 1.5)
            } else {
                Circle().fill(Palette.tone(tone))
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// Favorable, neutral and critical as three proportional segments; office headlines are never in it.
public struct ToneBar: View {
    let counts: ToneCounts
    let height: CGFloat

    public init(_ counts: ToneCounts, height: CGFloat = 22) {
        self.counts = counts
        self.height = height
    }

    /// The bar read aloud: `Coverage tone: 2 favorable, 13 neutral, 5 critical.`
    nonisolated public static func spoken(_ counts: ToneCounts) -> String {
        "Coverage tone: \(counts.sentence)."
    }

    public var body: some View {
        let parts = [(counts.favorable, Palette.toneFavorable), (counts.neutral, Palette.toneNeutral),
                     (counts.critical, Palette.toneCritical)].filter { $0.0 > 0 }
        let total = CGFloat(counts.counted)
        GeometryReader { geo in
            let gaps = CGFloat(max(0, parts.count - 1)) * 3
            HStack(spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 4).fill(part.1)
                        .frame(width: total > 0 ? max(0, geo.size.width - gaps) * CGFloat(part.0) / total : 0)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Self.spoken(counts))
    }
}

/// The violet AI READ chip, in the AI PICKED chip's style.
public struct AIReadChip: View {
    public init() {}

    public var body: some View {
        Text("AI READ")
            .scaledFont(Typography.News.aiChip, weight: .heavy)
            .tracking(1)
            .foregroundStyle(Palette.aiInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.ai, in: .rect(cornerRadius: 5))
            .accessibilityLabel("Read by AI")
    }
}

/// A headline (`.hl`): the tone dot, the title, `Source · Nov 17`, and "From their office" on the
/// member's own releases. Opens its link.
public struct HeadlineRow: View {
    let headline: Headline
    let calendar: Calendar
    /// The hairline above the row; the first row in a card leaves it out.
    let rule: Bool
    @Environment(\.openURL) private var openURL

    public init(_ headline: Headline, calendar: Calendar, rule: Bool = true) {
        self.headline = headline
        self.calendar = calendar
        self.rule = rule
    }

    /// `The Hill · Nov 17`, the day in the reader's calendar.
    nonisolated public static func sourceLine(_ headline: Headline, calendar: Calendar) -> String {
        let day = headline.publishedDate.map { date in
            var style = Date.FormatStyle(locale: calendar.locale ?? Locale(identifier: "en_US"), calendar: calendar,
                                         timeZone: calendar.timeZone).month(.abbreviated).day()
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        return [headline.source.isEmpty ? nil : headline.source, day].compactMap(\.self).joined(separator: " · ")
    }

    /// Title, source, date and tone: `Schumer declares …, The Hill, Nov 17, favorable coverage`.
    nonisolated public static func spoken(_ headline: Headline, calendar: Calendar) -> String {
        [headline.displayTitle, sourceLine(headline, calendar: calendar).replacingOccurrences(of: " · ", with: ", "),
         headline.tone?.spoken].compactMap(\.self).joined(separator: ", ")
    }

    public var body: some View {
        Button { if let url = headline.link { openURL(url) } } label: {
            HStack(alignment: .top, spacing: 10) {
                if headline.tone != nil {
                    ToneDot(headline.tone).padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline.displayTitle)
                        .scaledFont(Typography.News.headline, weight: .semibold)
                        .foregroundStyle(Palette.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(Self.sourceLine(headline, calendar: calendar))
                            .scaledFont(Typography.News.source)
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if headline.tone == .office {
                            Text("From their office")
                                .scaledFont(Typography.News.officeTag, weight: .bold)
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Palette.chip, in: .rect(cornerRadius: 5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .overlay(alignment: .top) {
                if rule { Rectangle().fill(Palette.cardBorder).frame(height: 1) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(headline, calendar: calendar))
        .accessibilityHint("Opens the article")
        .accessibilityAddTraits(.isLink)
    }
}

/// A dashed card for what is missing and how to get it (`.need`): a line, and an optional button.
public struct DashedNote: View {
    let text: String
    let action: (title: String, run: () -> Void)?

    public init(_ text: String, action: (title: String, run: () -> Void)? = nil) {
        self.text = text
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .scaledFont(Typography.Local.note)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.run) {
                    Text(action.title)
                        .scaledFont(Typography.Local.button, weight: .bold)
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Palette.text, in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// A screen's chip row (`.chips`): the selected chip white, the rest on the chip fill. Scrolls
/// sideways; wraps at the largest text sizes so no label is cut.
public struct FilterChips<ID: Hashable>: View {
    let items: [(id: ID, label: String)]
    @Binding var selection: ID
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ items: [(id: ID, label: String)], selection: Binding<ID>) {
        self.items = items
        _selection = selection
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            // One chip a line, each free to wrap: a flow layout measures a chip on one line and
            // would let a wrapped one overlap the next.
            VStack(alignment: .leading, spacing: 6) { chips }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { chips }.padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    private var chips: some View {
        ForEach(items, id: \.id) { item in
            let on = item.id == selection
            Button { selection = item.id } label: {
                Text(item.label)
                    .scaledFont(Typography.News.filter, weight: .semibold)
                    .foregroundStyle(on ? Palette.verdictInk : Palette.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? nil : 240)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    // Under half the chip's height (lesson 68).
                    .background(on ? Palette.verdict : Palette.chip, in: .rect(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(on ? Color.clear : Palette.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.label)
            .accessibilityAddTraits(on ? [.isSelected] : [])
        }
    }
}

// MARK: - Links in a Safari view

public extension View {
    /// Every link opened beneath this view (`openURL`) opens in a Safari view over the screen rather
    /// than leaving the app: headlines, polls' releases, a law's page.
    func opensLinksInSafariView() -> some View {
        modifier(SafariLinks())
    }
}

private struct SafariLinks: ViewModifier {
    @State private var shown: IdentifiedURL?

    func body(content: Content) -> some View {
        #if canImport(SafariServices) && os(iOS)
        content
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "https" || url.scheme == "http" else { return .systemAction }
                shown = IdentifiedURL(url: url)
                return .handled
            })
            .sheet(item: $shown) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
        #else
        content
        #endif
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if canImport(SafariServices) && os(iOS)
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
