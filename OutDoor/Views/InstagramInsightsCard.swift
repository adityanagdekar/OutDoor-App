import SwiftUI

struct InstagramInsightsCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot = InstagramInsightsSnapshot.empty
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Instagram Insights", systemImage: "chart.bar.fill")
                .font(.headline)

            InsightsValueRow(
                title: "Available Instagram quota",
                value: formattedMinutes(snapshot.availableCreditSeconds)
            )
            InsightsValueRow(
                title: "Estimated Instagram usage today",
                value: formattedMinutes(snapshot.estimatedUsageTodaySeconds)
            )
            InsightsValueRow(
                title: "Estimated excess usage today",
                value: formattedMinutes(snapshot.estimatedExcessTodaySeconds)
            )
            InsightsValueRow(
                title: "Verified walking today",
                value: "Not connected yet"
            )

            Text("Instagram values are estimated from Shortcuts.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task {
            await refreshInsights()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            Task {
                await refreshInsights()
            }
        }
    }

    /// Displays persisted seconds as rounded whole minutes.
    private func formattedMinutes(_ duration: TimeInterval) -> String {
        let minutes = max(0, duration / 60).rounded()
        return "\(Int(minutes)) min"
    }

    /// Reloads the latest values after intents or app lifecycle changes.
    private func refreshInsights() async {
        do {
            snapshot = try await InstagramAccountingStore.shared.insights()
            errorMessage = nil
            OutDoorLog.insights(
                "INSIGHTS_UI_REFRESHED availableSeconds=\(snapshot.availableCreditSeconds) usageTodaySeconds=\(snapshot.estimatedUsageTodaySeconds) excessTodaySeconds=\(snapshot.estimatedExcessTodaySeconds)"
            )
        } catch {
            errorMessage = error.localizedDescription
            OutDoorLog.error("Insights", "INSIGHTS_UI_REFRESH_FAILED error=\(error.localizedDescription)")
        }
    }
}

private struct InsightsValueRow: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        } label: {
            Text(title)
        }
        .font(.subheadline)
    }
}
