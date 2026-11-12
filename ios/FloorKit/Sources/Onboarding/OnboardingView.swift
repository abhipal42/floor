import APIClient
import DesignSystem
import Models
import SwiftUI

/// Asks for an address, shows who it resolves to, and saves it once confirmed.
///
/// The canvas has no onboarding artboard, so this is drawn from its tokens: the same near-black
/// ground, 22pt cards, mint accent and party colours used on Home.
public struct OnboardingView: View {
    @State private var model: OnboardingModel
    @FocusState private var addressFocused: Bool
    private let onFinished: (Delegation) -> Void

    public init(model: OnboardingModel, onFinished: @escaping (Delegation) -> Void) {
        _model = State(initialValue: model)
        self.onFinished = onFinished
    }

    public var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    addressField
                    if case let .found(reps) = model.phase {
                        resolved(reps)
                    }
                    if case let .failed(message) = model.phase {
                        failure(message)
                    }
                    footnote
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who represents you?")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Palette.text)
            Text("Your address finds your district, so Floor can show how your own members vote.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                // Typing again after a failure clears it, so the error never contradicts the field.
                if case .failed = model.phase { model.edit() }
            }
            .font(.system(size: 16))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Palette.card, in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).stroke(Palette.cardBorder, lineWidth: 1)
            )
            .accessibilityLabel("Your address")

            Button {
                addressFocused = false
                Task { await model.lookUp() }
            } label: {
                HStack(spacing: 8) {
                    if model.phase == .looking {
                        ProgressView().controlSize(.small).tint(Palette.ground)
                    }
                    Text(model.phase == .looking ? "Looking up…" : "Find my representatives")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(model.canLookUp ? Palette.accent : Palette.chip, in: .rect(cornerRadius: 16))
                .foregroundStyle(model.canLookUp ? Palette.ground : Palette.textMuted)
            }
            .disabled(!model.canLookUp)
        }
    }

    private func resolved(_ reps: Reps) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reps.district.name)
                .font(Typography.eyebrow)
                .tracking(0.8)
                .foregroundStyle(Palette.accentSoft)

            VStack(spacing: 0) {
                ForEach(Array(reps.members.enumerated()), id: \.element.bioguideId) { index, member in
                    if index > 0 {
                        Divider().overlay(Palette.track)
                    }
                    memberRow(member)
                }
            }
            .background(Palette.card, in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.cardBorder, lineWidth: 1))

            HStack(spacing: 12) {
                Button("Not me") { model.edit() }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Palette.chip, in: .rect(cornerRadius: 16))
                    .foregroundStyle(Palette.textSecondary)

                Button("That's right") {
                    if let delegation = model.confirm() { onFinished(delegation) }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Palette.accent, in: .rect(cornerRadius: 16))
                .foregroundStyle(Palette.ground)
            }
        }
        .transition(.opacity)
    }

    private func memberRow(_ member: Member) -> some View {
        HStack(spacing: 12) {
            Text(initials(member))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(width: 42, height: 42)
                .background(Palette.partyTint(member.party), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.fullName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(role(member))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 8)
            Text(member.party)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.party(member.party))
                .frame(width: 26, height: 26)
                .background(Palette.party(member.party).opacity(0.16), in: .circle)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.fullName), \(role(member))")
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Palette.nay)
                .font(.system(size: 16))
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.nay.opacity(0.10), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var footnote: some View {
        Text("Your address is used once to find your district and is never stored.")
            .font(Typography.caption)
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func initials(_ member: Member) -> String {
        let first = member.firstName.first.map(String.init) ?? ""
        let last = member.lastName.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private func role(_ member: Member) -> String {
        switch member.chamber {
        case .house:
            member.district.map { "Representative, \(member.state)-\($0 == 0 ? "AL" : String($0))" }
                ?? "Representative, \(member.state)"
        case .senate:
            "Senator, \(member.state)"
        }
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
