import SwiftUI
import UIKit

struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionService = OutdoorSessionService()
    @State private var isShowingChallenges = false

    private var hasStartedSession: Bool {
        sessionService.sessionState != .ready
    }

    var body: some View {
        ZStack {
            SessionMapView(locationService: sessionService.locationService)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 12) {
                SessionStatusBanner(
                    activityState: sessionService.walkingActivityState,
                    trackingState: sessionService.locationService.trackingState,
                    motionAvailability: sessionService.motionFallbackAvailability,
                    shouldShowInactivityActions: sessionService.shouldShowInactivityActions,
                    hasProlongedInactivity: sessionService.hasProlongedInactivity,
                    locationErrorMessage: sessionService.locationService.locationError?.localizedDescription,
                    onAllowLocation: sessionService.requestLocationAuthorization,
                    onOpenSettings: openSettings,
                    onRetry: sessionService.retryLocationUpdates,
                    onContinue: sessionService.continueAfterInactivityWarning,
                    onEnd: endSession
                )

                WalkingTimeCard(
                    verifiedWalkingTime: sessionService.verifiedWalkingTime
                )

                Spacer()

                SessionControls(
                    hasStartedSession: hasStartedSession,
                    state: sessionService.locationService.trackingState,
                    distance: sessionService.estimatedDistance,
                    onStart: sessionService.startSession,
                    onPause: sessionService.pauseSession,
                    onResume: sessionService.resumeSession,
                    onShowChallenges: { isShowingChallenges = true },
                    onEnd: endSession,
                    onDone: dismiss.callAsFunction
                )
            }
            .padding()
        }
        .navigationTitle("Outdoor Session")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(sessionService.sessionState != .completed)
        .sheet(isPresented: $isShowingChallenges) {
            ChallengesSheet()
        }
        .onAppear {
            sessionService.requestMapLocation()
        }
        .onChange(of: scenePhase) {
            handleScenePhaseChange()
        }
        .onDisappear {
            abandonSessionIfNeeded()
        }
    }

    /// Ends an active session, or exits when tracking has not started.
    private func endSession() {
        guard hasStartedSession else {
            dismiss()
            return
        }

        sessionService.endSession()
    }

    /// Pauses both foreground sensor streams when the app enters the background.
    private func handleScenePhaseChange() {
        guard scenePhase == .background,
              sessionService.sessionState == .active else {
            return
        }

        sessionService.pauseSession()
    }

    /// Ends a session when leaving this screen, except during challenge presentation.
    private func abandonSessionIfNeeded() {
        guard hasStartedSession,
              !isShowingChallenges,
              sessionService.sessionState != .completed else {
            return
        }

        sessionService.endSession()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(url)
    }
}

private struct WalkingTimeCard: View {
    let verifiedWalkingTime: TimeInterval

    var body: some View {
        VStack(spacing: 4) {
            Text("Walking Time")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formattedTime(verifiedWalkingTime))
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .frame(maxWidth: 240)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    /// Formats session durations as hours and minutes.
    private func formattedTime(_ duration: TimeInterval) -> String {
        let totalMinutes = max(Int(duration) / 60, 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%02d:%02d", hours, minutes)
    }
}

private struct SessionStatusBanner: View {
    let activityState: WalkingActivityState
    let trackingState: TrackingState
    let motionAvailability: OutdoorSessionService.MotionFallbackAvailability
    let shouldShowInactivityActions: Bool
    let hasProlongedInactivity: Bool
    let locationErrorMessage: String?
    let onAllowLocation: () -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void
    let onContinue: () -> Void
    let onEnd: () -> Void

    @ViewBuilder
    var body: some View {
        switch activityState {
        case .ready:
            StatusMessage(
                icon: "figure.walk",
                title: "Ready for Your Walk",
                message: "Tap Start when you are ready. As a suggestion, walk for 30 minutes to earn 30 minutes of Instagram time."
            )
        case .paused:
            StatusMessage(
                icon: "pause.circle",
                title: "Session Paused",
                message: "Walking time is not being earned until you resume."
            )
        case .completed:
            StatusMessage(
                icon: "checkmark.circle",
                title: "Session Completed",
                message: "Your earned walking time is final."
            )
        case .acquiringMovement, .walking, .stationary:
            activeStatusContent
        }
    }

    @ViewBuilder
    private var activeStatusContent: some View {
        if motionAvailability == .unavailable {
            StatusMessage(
                icon: "figure.walk.motion",
                title: "Motion Access Unavailable",
                message: "Walking cannot be verified, so usage time is not currently being earned."
            )
        } else {
            switch trackingState {
            case .permissionNotRequested:
                StatusMessage(
                    icon: "location.slash",
                    title: "Location Access Unavailable",
                    message: "Allow location access to show your position. \(locationEarningMessage)"
                ) {
                    Button("Allow Location", action: onAllowLocation)
                        .buttonStyle(.borderedProminent)
                }
            case .permissionDenied:
                StatusMessage(
                    icon: "location.slash",
                    title: "Location Access Unavailable",
                    message: "Your map position is unavailable. \(locationEarningMessage)"
                ) {
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                }
            case .permissionRestricted:
                StatusMessage(
                    icon: "location.slash",
                    title: "Location Access Unavailable",
                    message: "Location is restricted. \(locationEarningMessage)"
                )
            case .locationUnavailable:
                StatusMessage(
                    icon: "location.slash",
                    title: "Location Access Unavailable",
                    message: locationUnavailableMessage
                ) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            case .waitingForAccurateFix, .tracking:
                walkingStatusContent
            case .paused, .completed:
                walkingStatusContent
            }
        }
    }

    @ViewBuilder
    private var walkingStatusContent: some View {
        switch activityState {
        case .acquiringMovement:
            StatusMessage(
                icon: "figure.walk",
                title: "Detecting Movement",
                message: "Start walking to earn usage time. No time is being earned yet."
            ) {
                ProgressView()
            }
        case .walking:
            StatusMessage(
                icon: "figure.walk.motion",
                title: "Walking Time Active",
                message: "Walking is verified and usage time is currently being earned."
            )
        case .stationary where shouldShowInactivityActions:
            StatusMessage(
                icon: "figure.stand",
                title: "No Movement Detected",
                message: inactivityMessage
            ) {
                VStack(spacing: 8) {
                    Button("Continue Session", action: onContinue)
                        .buttonStyle(.borderedProminent)

                    Button("End Session", role: .destructive, action: onEnd)
                        .buttonStyle(.bordered)
                }
            }
        case .stationary:
            StatusMessage(
                icon: "figure.stand",
                title: "No Movement Detected",
                message: "Your earned time is preserved, but no additional usage time is being earned."
            )
        case .ready, .paused, .completed:
            EmptyView()
        }
    }

    private var locationUnavailableMessage: String {
        guard let locationErrorMessage else {
            return "Your map position is unavailable. \(locationEarningMessage)"
        }

        return "\(locationErrorMessage) \(locationEarningMessage)"
    }

    private var locationEarningMessage: String {
        switch activityState {
        case .walking:
            return "Walking is verified and usage time is still being earned."
        case .acquiringMovement:
            return "Motion is detecting movement, but usage time is not being earned yet."
        case .stationary:
            return "Earned time is preserved, but no additional usage time is being earned."
        case .ready, .paused, .completed:
            return "Walking time is not currently being earned."
        }
    }

    private var inactivityMessage: String {
        if hasProlongedInactivity {
            return "You have been inactive for an extended period. Earned time is preserved; continue waiting or end the session."
        }

        return "You have been stationary for several minutes. Earned time is preserved; continue waiting or end the session."
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
                Text("Estimated Distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(distance.formatted(.number.precision(.fractionLength(0)))) m")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()

                Text("Motion estimate")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
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
