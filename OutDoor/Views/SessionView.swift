import SwiftUI
import UIKit

struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationService = LocationService()
    @State private var hasStartedSession = false
    @State private var isShowingChallenges = false

    var body: some View {
        ZStack {
            SessionMapView(locationService: locationService)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 12) {
                SessionStatusBanner(
                    hasStartedSession: hasStartedSession,
                    state: locationService.trackingState,
                    horizontalAccuracy: locationService.horizontalAccuracy,
                    errorMessage: locationService.locationError?.localizedDescription,
                    onAllowLocation: locationService.requestWhenInUseAuthorization,
                    onOpenSettings: openSettings,
                    onRetry: locationService.retryLocationUpdates
                )

                Spacer()

                SessionControls(
                    hasStartedSession: hasStartedSession,
                    state: locationService.trackingState,
                    distance: locationService.totalDistance,
                    onStart: startSession,
                    onPause: locationService.pauseSession,
                    onResume: locationService.resumeSession,
                    onShowChallenges: { isShowingChallenges = true },
                    onEnd: endSession,
                    onDone: dismiss.callAsFunction
                )
            }
            .padding()
        }
        .navigationTitle("Outdoor Session")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(locationService.trackingState != .completed)
        .sheet(isPresented: $isShowingChallenges) {
            ChallengesSheet()
        }
        .onChange(of: scenePhase) {
            handleScenePhaseChange()
        }
        .onDisappear {
            abandonSessionIfNeeded()
        }
    }

    /// Starts tracking only after the user explicitly taps Start.
    private func startSession() {
        hasStartedSession = true
        locationService.startSession()

        if locationService.authorizationStatus == .notDetermined {
            locationService.requestWhenInUseAuthorization()
        }
    }

    /// Ends an active session, or exits when tracking has not started.
    private func endSession() {
        guard hasStartedSession else {
            dismiss()
            return
        }

        locationService.endSession()
    }

    /// Pauses active GPS work when the app is no longer visible.
    private func handleScenePhaseChange() {
        guard scenePhase == .background else {
            return
        }

        switch locationService.trackingState {
        case .waitingForAccurateFix, .tracking:
            locationService.pauseSession()
        case .permissionNotRequested, .permissionDenied, .permissionRestricted,
             .locationUnavailable, .paused, .completed:
            break
        }
    }

    /// Ends a session when leaving this screen, except during challenge presentation.
    private func abandonSessionIfNeeded() {
        guard hasStartedSession,
              !isShowingChallenges,
              locationService.trackingState != .completed else {
            return
        }

        locationService.endSession()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(url)
    }
}

private struct SessionStatusBanner: View {
    let hasStartedSession: Bool
    let state: TrackingState
    let horizontalAccuracy: CLLocationAccuracy?
    let errorMessage: String?
    let onAllowLocation: () -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        if !hasStartedSession {
            StatusMessage(
                icon: "figure.walk",
                title: "Ready for Your Walk",
                message: "Tap Start when you are ready to begin location tracking."
            )
        } else {
            statusContent
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state {
        case .permissionNotRequested:
            StatusMessage(
                icon: "location",
                title: "Location Access",
                message: "Allow location access to map your walk and calculate distance."
            ) {
                Button("Allow Location", action: onAllowLocation)
                    .buttonStyle(.borderedProminent)
            }
        case .permissionDenied:
            StatusMessage(
                icon: "location.slash",
                title: "Location Access Denied",
                message: "Enable location access for OutDoor in Settings to track this session."
            ) {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
        case .permissionRestricted:
            StatusMessage(
                icon: "location.slash",
                title: "Location Restricted",
                message: "Location access is restricted on this device and cannot be used for this session."
            )
        case .locationUnavailable:
            StatusMessage(
                icon: "exclamationmark.triangle",
                title: "Location Unavailable",
                message: errorMessage ?? "A location could not be determined. Check Location Services and try again."
            ) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        case .waitingForAccurateFix:
            StatusMessage(
                icon: "location.magnifyingglass",
                title: "Finding Your Location",
                message: accuracyMessage
            ) {
                ProgressView()
            }
        case .tracking:
            StatusMessage(
                icon: "location.fill",
                title: "Tracking Session",
                message: "Your accepted GPS route and distance are updating live."
            )
        case .paused:
            StatusMessage(
                icon: "pause.circle",
                title: "Session Paused",
                message: "Your route is preserved while location updates are stopped."
            )
        case .completed:
            StatusMessage(
                icon: "checkmark.circle",
                title: "Session Completed",
                message: "Location tracking has stopped and your final route is shown."
            )
        }
    }

    private var accuracyMessage: String {
        guard let horizontalAccuracy, horizontalAccuracy >= 0 else {
            return "Waiting for an accurate GPS fix."
        }

        return "Current GPS accuracy is about \(horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) meters."
    }
}

private struct StatusMessage<Accessory: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let message: String
    @ViewBuilder let accessory: () -> Accessory

    init(
        icon: String,
        title: LocalizedStringKey,
        message: String,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            accessory()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension StatusMessage where Accessory == EmptyView {
    init(
        icon: String,
        title: LocalizedStringKey,
        message: String
    ) {
        self.init(icon: icon, title: title, message: message) {
            EmptyView()
        }
    }
}

private struct SessionControls: View {
    let hasStartedSession: Bool
    let state: TrackingState
    let distance: CLLocationDistance
    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onShowChallenges: () -> Void
    let onEnd: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("Distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(distance.formatted(.number.precision(.fractionLength(0)))) m")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            controls
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var controls: some View {
        if !hasStartedSession {
            HStack(spacing: 12) {
                startButton
                challengesButton
                endButton
            }
        } else {
            switch state {
            case .tracking, .waitingForAccurateFix:
                HStack(spacing: 12) {
                    pauseButton
                    challengesButton
                    endButton
                }
            case .paused:
                HStack(spacing: 12) {
                    resumeButton
                    challengesButton
                    endButton
                }
            case .completed:
                SessionActionButton(
                    title: "Done",
                    systemImage: "checkmark",
                    tint: .green,
                    action: onDone
                )
            case .permissionNotRequested, .permissionDenied, .permissionRestricted, .locationUnavailable:
                HStack(spacing: 12) {
                    challengesButton
                    endButton
                }
            }
        }
    }

    private var startButton: some View {
        SessionActionButton(
            title: "Start",
            systemImage: "play.fill",
            tint: .green,
            action: onStart
        )
    }

    private var pauseButton: some View {
        SessionActionButton(
            title: "Pause",
            systemImage: "pause.fill",
            tint: .orange,
            action: onPause
        )
    }

    private var resumeButton: some View {
        SessionActionButton(
            title: "Resume",
            systemImage: "play.fill",
            tint: .green,
            action: onResume
        )
    }

    private var challengesButton: some View {
        SessionActionButton(
            title: "Challenges",
            systemImage: "camera.fill",
            tint: .blue,
            action: onShowChallenges
        )
    }

    private var endButton: some View {
        SessionActionButton(
            title: "End",
            systemImage: "stop.fill",
            tint: .red,
            role: .destructive,
            action: onEnd
        )
    }
}

private struct SessionActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var role: ButtonRole?
    let action: () -> Void

    init(
        title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }

                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct ChallengesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChallengesView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
