import SwiftUI

struct WelcomeView: View {
    @State private var notificationAuthorizationState = AllowanceReminderService.AuthorizationState.unknown
    @State private var insightsRefreshID = UUID()

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
                .id(insightsRefreshID)

            Spacer()

#if DEBUG
            InstagramAccountingDebugControls {
                insightsRefreshID = UUID()
            }
#endif

            NavigationLink("START") {
                SessionView {
                    insightsRefreshID = UUID()
                }
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
            OutDoorLog.debug("NOTIFICATION_PERMISSION_BUTTON_TAPPED")
            do {
                errorMessage = nil
                authorizationState = try await AllowanceReminderService.shared.requestAuthorization()
                OutDoorLog.debug("NOTIFICATION_PERMISSION_UI_UPDATED state=\(String(describing: authorizationState))")
            } catch {
                errorMessage = error.localizedDescription
                authorizationState = await AllowanceReminderService.shared.authorizationState()
                OutDoorLog.error("DebugControls", "NOTIFICATION_PERMISSION_UI_FAILED error=\(error.localizedDescription)")
            }
        }
    }
}

#if DEBUG
private struct InstagramAccountingDebugControls: View {
    let onAccountingChanged: () -> Void
    @State private var statusMessage = "TEST credit is separate from verified walking."
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 10) {
            Label("DEBUG – Instagram Accounting Test", systemImage: "ladybug.fill")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            Text(statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Reset TEST Accounting", role: .destructive) {
                resetTestAccounting()
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(isWorking)

            Button("Add 5 Minutes TEST Walking") {
                grantTestWalkingCredit()
            }
            .buttonStyle(.borderedProminent)
            .font(.caption)
            .disabled(isWorking)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func grantTestWalkingCredit() {
        Task {
            OutDoorLog.debug("GRANT_TEST_WALKING_BUTTON_TAPPED seconds=300")
            isWorking = true
            defer { isWorking = false }

            do {
                let entry = try await InstagramAccountingStore.shared.grantVerifiedWalkingCredit(
                    seconds: 300
                )
                statusMessage = "Added 5 minutes of TEST walking and Instagram credit."
                OutDoorLog.debug(
                    "GRANT_TEST_WALKING_COMPLETED entryID=\(entry.id.uuidString) seconds=\(entry.durationSeconds)"
                )
                onAccountingChanged()
            } catch {
                statusMessage = error.localizedDescription
                OutDoorLog.error(
                    "DebugControls",
                    "GRANT_TEST_WALKING_FAILED error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func resetTestAccounting() {
        Task {
            OutDoorLog.debug("RESET_TEST_ACCOUNTING_BUTTON_TAPPED")
            isWorking = true
            defer { isWorking = false }

            do {
                await AllowanceReminderService.shared.cancelAllAllowanceReminders()
                try await InstagramAccountingStore.shared.resetTestAccounting()
                statusMessage = "TEST accounting, sessions, reminders, and legacy access were reset."
                OutDoorLog.debug("RESET_TEST_ACCOUNTING_COMPLETED")
                onAccountingChanged()
            } catch {
                statusMessage = error.localizedDescription
                OutDoorLog.error("DebugControls", "RESET_TEST_ACCOUNTING_FAILED error=\(error.localizedDescription)")
            }
        }
    }
}
#endif

#Preview {
    NavigationStack {
        WelcomeView()
    }
}
