import APIClient
import DesignSystem
import Models
import SwiftUI

/// "Pull your three.": asks for an address, deals the three members it resolves to, and saves them
/// once confirmed. Follows the locked AppOnboarding mock.
///
/// The behaviour is ``OnboardingModel``'s, unchanged: the address is used for one request and never
/// stored. Typing again after a result goes back to editing, which is how a wrong match is
/// corrected — the mock has no separate "Not me" button.
public struct OnboardingView: View {
    @State private var model: OnboardingModel
    @FocusState private var addressFocused: Bool
    private let onFinished: (Delegation) -> Void

    public init(model: OnboardingModel, onFinished: @escaping (Delegation) -> Void) {
        _model = State(initialValue: model)
        self.onFinished = onFinished
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
                Text("Your address finds your district. Floor keeps the district and drops the street.")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                field
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
        .safeAreaInset(edge: .bottom) { cta.padding(.horizontal, 20).padding(.bottom, 8) }
        .background(alignment: .top) {
            LinearGradient(colors: [Palette.groundGlow, Palette.ground], startPoint: .top, endPoint: .bottom)
                .frame(height: 420)
                .ignoresSafeArea()
        }
        .background(Palette.ground)
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
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
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12).fill(Palette.card).frame(height: 150)
            }
        }
        .accessibilityLabel("Finding your members")
    }

    private func dealt(_ reps: Reps) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StateName.districtName(state: reps.district.state, district: reps.district.district).uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.yea)
            HStack(alignment: .top, spacing: 8) {
                ForEach(orderedMembers(reps)) { member in
                    memberCard(member)
                }
            }
        }
        .transition(.opacity)
    }

    /// Representative first, then senators, as the mock deals them.
    private func orderedMembers(_ reps: Reps) -> [Member] {
        reps.members.filter { $0.chamber == .house } + reps.members.filter { $0.chamber == .senate }
    }

    private func memberCard(_ member: Member) -> some View {
        let seat = member.chamber == .house ? "House · \(member.badgeText)" : "Senate · \(member.state)"
        return VStack(alignment: .leading, spacing: 0) {
            MemberPortrait(member, cornerRadius: 0).frame(height: 96)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.lastName.uppercased())
                    .font(Typography.label(15))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(seat).font(.system(size: 9)).foregroundStyle(Palette.textMuted)
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
        .accessibilityLabel("\(member.fullName), \(seat), \(PartyName.singular(member.party))")
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

private extension Member {
    /// `NY-8`, `WY-AL`.
    var badgeText: String {
        district.map { "\(state)-\($0 == 0 ? "AL" : String($0))" } ?? state
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

#Preview("Asking for an address") {
    // Points at the local dev server; the resolved state needs `npm run dev -w @floor/api`.
    OnboardingView(
        model: OnboardingModel(
            api: FloorAPI(baseURL: FloorAPI.localDevelopment),
            store: InMemoryDelegationStore()
        ),
        onFinished: { _ in }
    )
}
