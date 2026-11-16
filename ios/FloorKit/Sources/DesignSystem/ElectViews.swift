import Models
import SwiftUI

// The pieces a delegation changing hands is drawn with, built to the locked members-elect mock
// (https://claude.ai/artifact/Hod9RDLS1DgxapLeBcA3QY, section A): the LEAVING tag on the member
// going, the ELECT row under them, and the dashed card for a seat with no winner yet.

/// The departing member's tag: a muted outline (`.lv`).
public struct LeavingTag: View {
    public init() {}

    public var body: some View {
        Text("LEAVING")
            .font(Typography.label(10.5))
            .tracking(1)
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.raised, lineWidth: 1))
            .fixedSize()
    }
}

/// The ELECT tag (`.et`): filled, or outlined (`ghost`).
public struct ElectTag: View {
    let text: String
    let ghost: Bool

    public init(_ text: String = "ELECT", ghost: Bool = false) {
        self.text = text
        self.ghost = ghost
    }

    public var body: some View {
        Text(text)
            .font(Typography.label(10.5))
            .tracking(1)
            .foregroundStyle(ghost ? Palette.elect : Palette.electInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(ghost ? Color.clear : Palette.elect, in: .rect(cornerRadius: 4))
            .overlay {
                if ghost { RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.elect.opacity(0.55), lineWidth: 1) }
            }
            .fixedSize()
    }
}

/// A member-elect's initials in the elect-blue ring, a ground-coloured gap between (`.av.ring`).
public struct ElectAvatar: View {
    let elect: MemberElect
    let size: CGFloat

    public init(_ elect: MemberElect, size: CGFloat = 30) {
        self.elect = elect
        self.size = size
    }

    public var body: some View {
        MemberPortrait(elect.asMember)
            .frame(width: size, height: size)
            .padding(2)
            .overlay(Circle().strokeBorder(Palette.elect, lineWidth: 1.5))
    }
}

/// What a seat-change row says, from the environment's locale.
public enum SeatCaption {
    /// `Senator · Michigan`, `Representative · NY-12`; leaving, `Senator · leaves Jan 3, 2027`.
    public static func member(_ member: Member, leavingOn: String?, locale: Locale) -> String {
        let seat = member.chamber == .senate ? member.title : "\(member.title) · \(member.seatBadge)"
        if let leavingOn, let day = ElectText.day(leavingOn, locale: locale) { return "\(seat) · leaves \(day)" }
        return member.chamber == .senate ? "\(seat) · \(StateName.full(member.state))" : seat
    }

    /// `Senator-elect · takes office Jan 3`; a special election's winner, `… takes office when Ohio certifies`.
    public static func elect(_ elect: MemberElect, locale: Locale) -> String {
        let day = ElectText.takesOffice(elect, locale: locale)
        let seat = elect.chamber == .senate ? elect.title : "\(elect.title) · \(elect.asMember.seatBadge)"
        return "\(seat) · takes office \(day)"
    }
}

/// The panel every seat-change row sits on (`.mr`), its border elect blue for an elect.
private struct SeatRowSurface: ViewModifier {
    let elect: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(elect ? Palette.elect.opacity(0.35) : Palette.panelBorder, lineWidth: 1))
    }
}

/// A sitting member's row; dimmed, with the LEAVING tag, when `leavingOn` is set.
public struct SeatMemberRow<Trailing: View>: View {
    @Environment(\.locale) private var locale
    let member: Member
    let leavingOn: String?
    let caption: String?
    let trailing: Trailing

    /// - Parameter caption: what to print under the name; nil prints ``SeatCaption/member``.
    public init(_ member: Member, leavingOn: String?, caption: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.member = member
        self.leavingOn = leavingOn
        self.caption = caption
        self.trailing = trailing()
    }

    public var body: some View {
        let text = caption.map { base in
            leavingOn.flatMap { ElectText.day($0, locale: locale) }.map { "\(base) · leaves \($0)" } ?? base
        } ?? SeatCaption.member(member, leavingOn: leavingOn, locale: locale)
        HStack(spacing: 9) {
            MemberPortrait(member).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.fullName.uppercased())
                    .font(Typography.display(17, weight: .blackItalic))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(text).scaledFont(10.5, weight: .medium).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            // The caption already says when they leave.
            if leavingOn != nil { LeavingTag().accessibilityHidden(true) }
            trailing
        }
        .modifier(SeatRowSurface(elect: false))
        .opacity(leavingOn == nil ? 1 : 0.62)
        .accessibilityElement(children: .contain)
    }
}

public extension SeatMemberRow where Trailing == EmptyView {
    init(_ member: Member, leavingOn: String?, caption: String? = nil) {
        self.init(member, leavingOn: leavingOn, caption: caption) { EmptyView() }
    }
}

/// A member-elect's row (`.mr.el`), with the line saying who called the race under it.
public struct ElectRow: View {
    @Environment(\.locale) private var locale
    let elect: MemberElect

    public init(_ elect: MemberElect) {
        self.elect = elect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                ElectAvatar(elect)
                VStack(alignment: .leading, spacing: 2) {
                    Text(elect.fullName.uppercased())
                        .font(Typography.display(17, weight: .blackItalic))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(SeatCaption.elect(elect, locale: locale))
                        .scaledFont(10.5, weight: .medium).foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ElectTag()
                Image(systemName: "chevron.right")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityHidden(true)
            }
            .modifier(SeatRowSurface(elect: true))
            Text(ElectText.callLine(elect.call, locale: locale))
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens what Floor has on them before they take office")
    }
}

/// A seat with no winner yet (`.ph`): dashed, centred, never a name.
public struct PendingSeatCard: View {
    @Environment(\.locale) private var locale
    let seat: PendingSeat

    public init(_ seat: PendingSeat) {
        self.seat = seat
    }

    public var body: some View {
        let words = ElectText.pending(seat, locale: locale)
        DashedPlaceholder(title: words.title, body: words.body)
    }
}

/// The mocks' dashed placeholder (`.ph`): a headline and a line, for what does not exist yet.
public struct DashedPlaceholder: View {
    let title: String
    let text: String

    public init(title: String, body: String) {
        self.title = title
        self.text = body
    }

    public var body: some View {
        VStack(spacing: 5) {
            Text(title.uppercased())
                .font(Typography.display(18, weight: .blackItalic))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(text)
                .scaledFont(11, weight: .medium)
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
