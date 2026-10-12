import SwiftUI

struct ChallengesView: View {
    @State private var selectedChallenge: Challenge?

    private let challenges = Challenge.samples

    var body: some View {
        List(challenges) { challenge in
            ChallengeRow(challenge: challenge) {
                selectedChallenge = challenge
            }
        }
        .navigationTitle("Challenges on Walk")
        .fullScreenCover(item: $selectedChallenge) { challenge in
            CameraFlowView(challenge: challenge)
        }
    }
}

private struct ChallengeRow: View {
    let challenge: Challenge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: challenge.systemImage)
                    .font(.title2)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(challenge.title)
                        .font(.headline)

                    Text(challenge.instruction)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        ChallengesView()
    }
}
