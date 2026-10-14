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
                    state: sessionService.locationService.trackingState,
                    gpsReliability: sessionService.gpsReliability,
                    activeDistanceSource: sessionService.activeDistanceSource,
                    motionFallbackAvailability: sessionService.motionFallbackAvailability,
                    horizontalAccuracy: sessionService.locationService.horizontalAccuracy,
                    errorMessage: sessionService.locationService.locationError?.localizedDescription,
                    onAllowLocation: sessionService.requestLocationAuthorization,
                    onOpenSettings: openSettings,
                    onRetry: sessionService.retryLocationUpdates
                )

                WalkingTimeCard(
                    verifiedWalkingTime: sessionService.verifiedWalkingTime,
                    remainingTime: sessionService.remainingTime,
                    goalDuration: sessionService.goalDuration
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
    let remainingTime: TimeInterval
    let goalDuration: TimeInterval

    var body: some View {
        VStack(spacing: 4) {
            Text("Verified Walking Time")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formattedTime(verifiedWalkingTime))
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()

            Text("Goal \(formattedTime(goalDuration)) · \(formattedTime(remainingTime)) remaining")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
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
    let state: TrackingState
    let gpsReliability: GPSReliability
    let activeDistanceSource: DistanceSource?
    let motionFallbackAvailability: OutdoorSessionService.MotionFallbackAvailability
    let horizontalAccuracy: CLLocationAccuracy?
    let errorMessage: String?
    let onAllowLocation: () -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        switch activityState {
        case .ready:
            StatusMessage(
                icon: "figure.walk",
                title: "Ready for Your Walk",
                message: "Tap Start when you are ready to begin tracking your walk."
            )
        case .acquiringMovement:
            acquiringStatusContent
        case .walking:
            StatusMessage(
                icon: "figure.walk.motion",
                title: "Walking Verified",
                message: "Your verified walking time is increasing."
            )
        case .stationary:
            StatusMessage(
                icon: "figure.stand",
                title: "No Movement Detected",
                message: "Your session remains active, but stationary time does not earn usage time."
            )
        case .paused:
            StatusMessage(
                icon: "pause.circle",
                title: "Session Paused",
                message: "Time and sensor updates are paused until you resume."
            )
        case .completed:
            StatusMessage(
                icon: "checkmark.circle",
                title: "Session Completed",
                message: "Your verified walking time and estimated distance are final."
            )
        }
    }

    @ViewBuilder
    private var acquiringStatusContent: some View {
        if isLimitedTracking {
            StatusMessage(
                icon: "exclamationmark.triangle",
                title: "Limited Distance Tracking",
                message: "GPS is not reliable and Motion & Fitness fallback is unavailable. Distance will remain unchanged until reliable GPS returns."
            )
        } else if isUsingPedometerFallback {
            StatusMessage(
                icon: "figure.walk.motion",
                title: "Motion Fallback Active",
                message: "GPS is currently unreliable. Motion & Fitness is estimating distance until GPS recovers."
            )
        } else if isAcquiringGPS {
            StatusMessage(
                icon: "location.magnifyingglass",
                title: "Acquiring GPS",
                message: accuracyMessage
            ) {
                ProgressView()
            }
        } else {
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
                title: "Acquiring GPS",
                message: accuracyMessage
            ) {
                ProgressView()
            }
        case .tracking:
            StatusMessage(
                icon: "location.fill",
                title: "GPS Tracking",
                message: "Reliable GPS is updating your route and distance."
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
    }

    private var isLimitedTracking: Bool {
        isLiveLocationState
            && gpsReliability != .reliable
            && motionFallbackAvailability == .unavailable
    }

    private var isUsingPedometerFallback: Bool {
        isLiveLocationState && activeDistanceSource == .pedometer
    }

    private var isAcquiringGPS: Bool {
        isLiveLocationState
            && gpsReliability != .reliable
            && activeDistanceSource != .pedometer
    }

    private var isLiveLocationState: Bool {
        state == .waitingForAccurateFix || state == .tracking
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
