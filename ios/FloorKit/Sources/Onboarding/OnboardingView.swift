import APIClient
import DesignSystem
import Models
import SwiftUI

/// "Pull your three.": finds the district from where you are or from an address, deals the members
/// it resolves to, and saves them once confirmed. Follows the locked LocApp mock, which extends
/// AppOnboarding with "Use my location".
///
/// The behaviour is ``OnboardingModel``'s: the address and the location are each used for one
/// request and never stored. Typing again after an address result goes back to editing, which is
/// how a wrong match is corrected; a location result offers "Not your district? Type an address".
public struct OnboardingView: View {
    @State private var model: OnboardingModel
    @FocusState private var addressFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Set when the app leaves the screen for real — to Settings, say. The system alert only makes
    /// it inactive, so this tells a return from Settings apart from the alert closing.
    @State private var wasInBackground = false
    private let onFinished: (Delegation) -> Void
    /// "Skip, I'll pick members myself": nil hides the link. The app then runs with no district —
    /// Finals shows every final, Following starts empty — until you find your reps from there.
    private let onSkip: (() -> Void)?

    public init(model: OnboardingModel, onSkip: (() -> Void)? = nil, onFinished: @escaping (Delegation) -> Void) {
        _model = State(initialValue: model)
        self.onFinished = onFinished
        self.onSkip = onSkip
        FloorFonts.register()
    }

    private var failure: String? {
        if case let .failed(message) = model.phase { return message }
        return nil
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("FLOOR").font(Typography.headline(30)).foregroundStyle(Palette.text)
                // Two lines rather than one with a newline: the mock sets them at 0.84 line height,
                // and SwiftUI's lineSpacing cannot go below the font's own.
                VStack(alignment: .leading, spacing: -16) {
                    Text("PULL YOUR").foregroundStyle(Palette.text)
                    Text("THREE.").foregroundStyle(Palette.yea)
                }
                .font(Typography.headline(68))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Your location or address finds your district. Floor keeps the district and drops the rest.")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if model.offersLocation { locate }
                if let notice = model.notice { banner(notice) }
                if model.showsAddressField { field }
                switch model.phase {
                case .looking:
                    skeleton
                case let .found(reps):
                    dealt(reps)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                cta
                if let onSkip {
                    Button("Skip, I'll pick members myself", action: onSkip)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(Palette.textSecondary)
                        .disabled(model.phase == .looking)
                        .accessibilityHint("Follow members of Congress without giving a district")
                }
                Text("Floor keeps the district and drops the street — and the location.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textFaint)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Palette.groundGlow, Palette.ground], startPoint: .top, endPoint: .bottom)
                .frame(height: 420)
                .ignoresSafeArea()
        }
        .background(Palette.ground)
        .tint(Palette.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasInBackground = true }
            if phase == .active, wasInBackground {
                wasInBackground = false
                Task { await model.retryAfterSettings() }
            }
        }
    }

    private var locate: some View {
        VStack(spacing: 10) {
            Button {
                addressFocused = false
                Task { await model.useMyLocation() }
            } label: {
                HStack(spacing: 10) {
                    // The mock's glyph: a dot in a ring.
                    ZStack {
                        Circle().fill(Palette.yea).frame(width: 6, height: 6)
                        Circle().stroke(Palette.yea, lineWidth: 1.6).frame(width: 12.4, height: 12.4)
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                    Text("Use my location").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.text)
                }
                .frame(maxWidth: .infinity)
                .padding(15)
                .background(Palette.panel, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.yea, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.askingPermission)
            Text("or type an address")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMuted)
                .frame(maxWidth: .infinity)
        }
    }

    private func banner(_ notice: OnboardingModel.Notice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notice.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.nay)
            Text(notice.body)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if notice.opensSettings, let settings = Self.settingsURL {
                Button("Open Settings ›") { openURL(settings) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.yea)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.warningPanel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.warningBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Floor's own page in Settings, where its Location switch is.
    private static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        nil
        #endif
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your address").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.text)
            TextField(
                "",
                text: $model.address,
                prompt: Text("1100 Congress Ave, Austin, TX 78701").foregroundStyle(Palette.textMuted)
            )
            .addressFieldTraits()
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($addressFocused)
            .onSubmit { Task { await model.lookUp() } }
            .onChange(of: model.address) { _, _ in
                // Typing again clears a failure, and takes back a result that no longer matches
                // what is in the field.
                switch model.phase {
                case .failed, .found: model.edit()
                default: break
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(Palette.text)
            .padding(15)
            .background(Palette.panel, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(failure == nil ? Palette.panelBorder : Palette.liveText, lineWidth: 1)
            )
            .accessibilityLabel("Your address")
            if let failure {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.liveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FINDING YOUR DISTRICT…").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.textMuted)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12).fill(Palette.card).frame(height: 150)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding your district")
    }

    private func dealt(_ reps: Reps) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StateName.districtName(state: reps.district.state, district: reps.district.district).uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.yea)
            if dynamicTypeSize.isAccessibilitySize {
                // A third of the width cannot hold a surname and a seat at these sizes: one card
                // per row instead of the mock's three columns.
                VStack(spacing: 8) {
                    ForEach(orderedMembers(reps)) { member in
                        memberCard(member)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(orderedMembers(reps)) { member in
                        memberCard(member)
                    }
                    // Always three columns, as the mock's grid is: D.C.'s one card keeps a card's
                    // width rather than stretching across the row.
                    ForEach(0..<max(0, 3 - reps.members.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
            if let note = OnboardingModel.singleMemberNote(reps) {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.source == .location {
                Button("Not your district? Type an address") { model.typeAddressInstead() }
                    .font(.system(size: 12))
                    .underline()
                    .foregroundStyle(Palette.textMuted)
                    .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }

    /// Representative first, then senators, as the mock deals them.
    private func orderedMembers(_ reps: Reps) -> [Member] {
        reps.members.filter { $0.chamber == .house } + reps.members.filter { $0.chamber == .senate }
    }

    private func memberCard(_ member: Member) -> some View {
        let seat = member.seatCaption
        return VStack(alignment: .leading, spacing: 0) {
            MemberPortrait(member, cornerRadius: 0).frame(height: 96)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.lastName.uppercased())
                    .font(Typography.label(15))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(seat).scaledFont(9).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.panel)
        .clipShape(.rect(cornerRadius: 9))
        .padding(3)
        .background(LinearGradient(colors: Palette.silver, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.member(member))
    }

    private var cta: some View {
        let found: Bool = if case .found = model.phase { true } else { false }
        let looking = model.phase == .looking
        // Always the mock's green: tapping with nothing usable typed is how the field's error
        // appears, so the button only stands down while a lookup is in flight.
        let enabled = !looking
        return Button {
            addressFocused = false
            if found {
                if let delegation = model.confirm() { onFinished(delegation) }
            } else {
                Task { await model.lookUp() }
            }
        } label: {
            Text(found ? "Deal me in" : looking ? "Finding…" : "Find my three")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Palette.ground)
                .frame(maxWidth: .infinity)
                .padding(17)
                .background(Palette.yea, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private extension View {
    /// Address-entry affordances that exist only on iOS. The package also builds for macOS, where
    /// `swift test` runs the models, so these cannot be applied unconditionally.
    @ViewBuilder
    func addressFieldTraits() -> some View {
        #if os(iOS)
        self.textContentType(.fullStreetAddress)
            .textInputAutocapitalization(.words)
        #else
        self
        #endif
    }
}

#Preview("Asking for an address or location") {
    // Points at the local dev server; the resolved state needs `npm run dev -w @floor/api`.
    OnboardingView(
        model: OnboardingModel(
            api: FloorAPI(baseURL: FloorAPI.localDevelopment),
            store: InMemoryDelegationStore()
        ),
        onFinished: { _ in }
    )
}
