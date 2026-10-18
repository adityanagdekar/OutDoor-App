import SwiftUI

struct WelcomeView: View {
    @State private var notificationAuthorizationState = AllowanceReminderService.AuthorizationState.unknown

#if DEBUG
    @State private var debugAccessExpiration = InstagramAccessStore.expirationDate
#endif

    var body: some View {
        ScrollView {
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

            NotificationPermissionCard(
                authorizationState: $notificationAuthorizationState
            )

            InstagramInsightsCard()

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
}

private struct NotificationPermissionCard: View {
    @Binding var authorizationState: AllowanceReminderService.AuthorizationState
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allowance Reminder", systemImage: "bell")
                .font(.headline)

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if authorizationState == .notRequested {
                Button("Enable Reminder Notifications") {
                    requestAuthorization()
                }
                .buttonStyle(.bordered)
            }

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
            authorizationState = await AllowanceReminderService.shared.authorizationState()
        }
    }

    private var statusMessage: LocalizedStringResource {
        switch authorizationState {
        case .unknown:
            "Checking notification permission…"
        case .notRequested:
            "Enable one reminder when your active Instagram allowance is exhausted."
        case .authorized:
            "Allowance reminders are enabled. Delivery and sound depend on your iPhone settings."
        case .denied:
            "Notifications are disabled. Usage accounting will continue without reminders."
        case .provisional:
            "Allowance reminders are provisionally enabled by iOS."
        }
    }

    private func requestAuthorization() {
        Task {
            do {
                errorMessage = nil
                authorizationState = try await AllowanceReminderService.shared.requestAuthorization()
            } catch {
                errorMessage = error.localizedDescription
                authorizationState = await AllowanceReminderService.shared.authorizationState()
            }
        }
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
