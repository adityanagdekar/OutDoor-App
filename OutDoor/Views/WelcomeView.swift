import SwiftUI

struct WelcomeView: View {
#if DEBUG
    @State private var debugAccessExpiration = InstagramAccessStore.expirationDate
#endif

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

#if DEBUG
            InstagramAccessDebugControls(expirationDate: $debugAccessExpiration)
#endif

            NavigationLink("START") {
                SessionView()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 32)
        }
        .padding()
    }
}

#if DEBUG
private struct InstagramAccessDebugControls: View {
    @Binding var expirationDate: Date?

    var body: some View {
        VStack(spacing: 10) {
            Label("DEBUG – Instagram Access Test", systemImage: "ladybug.fill")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Grant 1 Minute TEST Access") {
                    expirationDate = InstagramAccessStore.grantAccess(for: 60)
                }
                .buttonStyle(.bordered)

                Button("Clear TEST Access", role: .destructive) {
                    InstagramAccessStore.clearAccess()
                    expirationDate = nil
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        guard let expirationDate else {
            return "No test access is stored."
        }

        if expirationDate > Date() {
            return "Test access expires at \(expirationDate.formatted(date: .omitted, time: .standard))."
        }

        return "The stored test access has expired."
    }
}
#endif

#Preview {
    NavigationStack {
        WelcomeView()
    }
}
