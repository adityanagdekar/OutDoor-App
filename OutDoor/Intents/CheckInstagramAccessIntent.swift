import AppIntents

struct CheckInstagramAccessIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Instagram Access"
    static let description = IntentDescription(
        "Returns whether OutDoor's saved Instagram access window is currently active."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some ReturnsValue<Bool> {
        .result(value: InstagramAccessStore.hasActiveAccess())
    }
}
