import APIClient
import DesignSystem
import Models
import Onboarding
import SwiftUI

@main
struct FloorApp: App {
    private let store = UserDefaultsDelegationStore()
    private let api = FloorAPI(baseURL: FloorApp.apiBaseURL)
    @State private var delegation: Delegation?

    init() {
        // Read once at launch, before any screen exists, so the first frame is the right one.
        _delegation = State(initialValue: UserDefaultsDelegationStore().load())
    }

    /// Where the API lives.
    ///
    /// Taken from the `FloorAPIBaseURL` Info.plist key when it is set, so staging and production
    /// builds differ by configuration rather than code. Until the API is deployed there is nothing
    /// to point at, so this falls back to the local dev server: run `npm run dev -w @floor/api`
    /// and the Simulator reaches it on localhost.
    static var apiBaseURL: URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FloorAPIBaseURL") as? String,
           let url = URL(string: configured) {
            return url
        }
        return FloorAPI.localDevelopment
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let delegation {
                    HomeView(delegation: delegation, onStartOver: startOver)
                } else {
                    OnboardingView(model: OnboardingModel(api: api, store: store)) { saved in
                        withAnimation { delegation = saved }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func startOver() {
        store.clear()
        withAnimation { delegation = nil }
    }
}

/// Placeholder until the Home screen is built: shows the delegation onboarding resolved, so the
/// stored result is visible and onboarding can be run again.
struct HomeView: View {
    let delegation: Delegation
    let onStartOver: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(delegation.district.name)
                        .font(Typography.eyebrow)
                        .tracking(0.8)
                        .foregroundStyle(Palette.accentSoft)

                    ForEach(delegation.members) { member in
                        HStack(spacing: 12) {
                            Text(member.party)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.party(member.party))
                                .frame(width: 28, height: 28)
                                .background(Palette.party(member.party).opacity(0.16), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.fullName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Palette.text)
                                Text(member.chamber == .house ? "Representative" : "Senator")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textMuted)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(Palette.card, in: .rect(cornerRadius: 18))
                    }

                    Text("Recent votes land here next.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textMuted)
                        .padding(.top, 4)

                    ScoreboardCard(vote: .sample, title: "H.Con.Res. 14 · FY2025 Budget Resolution")

                    Button("Change my address", action: onStartOver)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .navigationTitle("Floor")
            .background(Palette.ground)
        }
    }
}
