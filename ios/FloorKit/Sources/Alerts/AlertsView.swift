import DesignSystem
import Models
import Onboarding
import SwiftUI

/// The Alerts screen, reached from Following's top bar: round 9's "Alerts" (section C of
/// https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre) with round 8's two pushes
/// (https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn, section C), extended to bills you follow.
public struct AlertsView: View {
    @State private var model: AlertsModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Settings › Floor, where notifications are turned back on (`UIApplication.openSettingsURLString`).
    private static let settings = URL(string: "app-settings:")!

    public init(model: AlertsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("ALERTS")
                    .font(Typography.headline(28))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)
                if let notice = model.notice { noticeCard(notice) }
                if model.isEmpty {
                    emptyCard
                } else {
                    if !model.members.isEmpty {
                        groupHeader("HOW THEY VOTED")
                        ForEach(model.members) { row in
                            switchRow(
                                title: row.member.lastName.uppercased(), caption: row.caption, on: row.on,
                                label: "\(row.member.fullName), \(row.caption)",
                                hint: "Alerts you when \(row.member.lastName)'s vote is final"
                            ) { on in await model.setMember(row.id, on) }
                        }
                    }
                    if !model.bills.isEmpty || model.followsTopics {
                        groupHeader("BILLS YOU FOLLOW").padding(.top, 8)
                        ForEach(model.steps) { row in
                            switchRow(
                                title: row.title, caption: row.caption, on: row.on, display: false,
                                label: "Bills you follow: \(row.title)",
                                hint: row.id == "throughTopics"
                                    ? "Bills in the topics you follow alert as if you followed them"
                                    : "Alerts you when a bill you follow reaches this step"
                            ) { on in await model.setStep(row.step, on) }
                        }
                    }
                    if !model.bills.isEmpty {
                        groupHeader("EACH BILL'S FINAL VOTES").padding(.top, 8)
                        ForEach(model.bills) { row in
                            switchRow(
                                title: row.citation.uppercased(), caption: row.label ?? "Voted on", on: row.on,
                                label: "\(row.citation)\(row.label.map { ", \($0)" } ?? "")",
                                hint: "Alerts you when a vote on \(row.citation) is final"
                            ) { on in await model.setBill(row.id, on) }
                        }
                    }
                    groupHeader("A VOTE OPENED").padding(.top, 8)
                    switchRow(
                        title: "VOTES INVOLVING YOUR MEMBERS", caption: "Off by default",
                        on: model.voteOpened, label: "A vote opened: votes involving your members",
                        hint: "Sends an alert when a vote involving your members or bills opens"
                    ) { on in await model.setVoteOpened(on) }
                    groupHeader("LIVE ACTIVITIES").padding(.top, 8)
                    switchRow(
                        title: "ON YOUR LOCK SCREEN", caption: "On by default · silent, until the vote is final",
                        on: model.liveActivities, label: "Live Activities",
                        hint: "Shows an open vote involving your members or bills on your lock screen and in the Dynamic Island, without a sound"
                    ) { on in await model.setLiveActivities(on) }
                    footnote
                }
                if let cloud = model.cloud {
                    groupHeader("SETTINGS").padding(.top, 14)
                    CloudSyncRow(cloud: cloud, switchRow: { on, set in
                        switchRow(
                            title: "Sync with iCloud",
                            caption: "Your follows, alert choices and district, on your devices only. Floor never sees them.",
                            on: on, display: false, label: "Sync with iCloud",
                            hint: "Keeps what you follow the same on your other devices, through your own iCloud", set: set
                        )
                    })
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.ground)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    // MARK: Pieces

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.label(12))
            .tracking(1.2)
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 2)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// The mock's `.mr` row with its switch: name in the display face, caption under it.
    /// `display: false` is the mock's `.srow`: the title in the text face, for sentences rather
    /// than names.
    private func switchRow(
        title: String, caption: String?, on: Bool, display: Bool = true, label: String, hint: String,
        set: @escaping (Bool) async -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { value in Task { await set(value) } })) {
            VStack(alignment: .leading, spacing: 2) {
                if display {
                    Text(title)
                        .font(Typography.display(17, weight: .blackItalic))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(title)
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caption {
                    Text(caption)
                        .scaledFont(10.5, weight: .medium)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(display ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: !display)
                }
            }
        }
        .toggleStyle(FloorSwitch())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 12)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func noticeCard(_ notice: AlertsModel.Notice) -> some View {
        let (title, body, button): (String, String, String) = switch notice {
        case .askPermission:
            ("FLOOR CAN'T ALERT YOU YET", "Your choices here are saved. Floor needs your permission to send them.", "ALLOW NOTIFICATIONS")
        case .permissionDenied:
            ("NOTIFICATIONS ARE OFF FOR FLOOR", "Your choices here are saved. Turn notifications on in Settings for them to reach you.", "OPEN SETTINGS")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.nay)
            Text(body).scaledFont(13).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button {
                if notice == .askPermission { Task { await model.allow() } } else { openURL(Self.settings) }
            } label: {
                Text(button)
                    .font(Typography.label(14))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.threshold, in: .rect(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warningPanel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.warningBorder, lineWidth: 1))
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTHING TO ALERT YOU ABOUT YET").font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.textMuted)
            Text("Find your reps or follow members, bills and topics, and their votes and steps can alert you here.")
                .scaledFont(13)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    /// The mock's `.sw`: a 40 × 24 track, yea green when on, with a white knob. Drawn rather than the
    /// system switch so it matches the mock in both appearances (and draws in the snapshot tests,
    /// where iOS 26's glass switch renders without its knob). Still a `Toggle`, so VoiceOver reads a
    /// switch with its value, and a double tap flips it.
    struct FloorSwitch: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? Palette.yea : Palette.raised)
                    .frame(width: 40, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color.white).frame(width: 20, height: 20).padding(2)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    }
                    .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(.rect)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Each alert says what happened and nothing about why. A busy night collapses into one summary.")
            if model.followsTopics, !model.follows.state.billSteps.throughTopics {
                Text("Topics you follow don't alert unless Through topics too is on: one is hundreds of bills. Their votes are in Finals.")
            }
            if model.overCap {
                Text("You follow more than 1,000 members, bills and topics; alerts cover the first 1,000.")
            }
        }
        .scaledFont(11.5)
        .foregroundStyle(Palette.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
        .padding(.top, 10)
    }
}

/// "Sync with iCloud" and its "Last synced" line (round 11, section F). In a build without the
/// iCloud entitlement it is a visible placeholder saying so, not a switch that does nothing.
struct CloudSyncRow<Row: View>: View {
    let cloud: CloudSync
    let switchRow: (Bool, @escaping (Bool) async -> Void) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch cloud.status {
            case .unavailable:
                VStack(alignment: .leading, spacing: 4) {
                    Text("SYNC WITH ICLOUD").font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.textMuted)
                    Text("iCloud isn't available in this build of Floor, so what you follow stays on this phone.")
                        .scaledFont(12.5)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityElement(children: .combine)
            case .off:
                switchRow(false) { on in cloud.setEnabled(on) }
            case let .on(lastSynced):
                switchRow(true) { on in cloud.setEnabled(on) }
                Text(Self.lastSyncedLine(lastSynced, summary: cloud.summary))
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, 2)
            case .tooLarge:
                switchRow(true) { on in cloud.setEnabled(on) }
                Text("You follow more than iCloud can hold in one record, so nothing new was synced.")
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Palette.nay)
                    .padding(.horizontal, 2)
            }
        }
    }

    /// `Last synced 9:38 · 6 members, 3 bills, 2 topics`; `Not synced yet · …`.
    static func lastSyncedLine(_ date: Date?, summary: String) -> String {
        guard let date else { return "Not synced yet · \(summary)" }
        let when = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "Last synced \(when) · \(summary)"
    }
}
