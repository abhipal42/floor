import DesignSystem
import Models
import SwiftUI

@main
struct FloorApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
        }
    }
}

/// M0 placeholder for the Home screen: one real final vote rendered with the design system.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Final")
                        .font(.headline)
                    ScoreboardCard(vote: .sample, title: "H.Con.Res. 14 · FY2025 Budget Resolution")
                }
                .padding(.horizontal, 14)
            }
            .navigationTitle("Floor")
            .background(Color.black)
        }
    }
}
