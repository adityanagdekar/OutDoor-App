import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "figure.walk")
                .font(.system(size: 72))

            VStack(spacing: 8) {
                Text("Welcome to")
                    .font(.title2)

                Text("OutDoor")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }

            Text("Complete outdoor photo challenges and spend more time exploring.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            NavigationLink("START") {
                ChallengesView()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        WelcomeView()
    }
}
