import AppIntents

struct EndInstagramSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "End Instagram Session"
    static let description = IntentDescription(
        "Finalizes the active estimated Instagram usage session without opening OutDoor."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        if let session = try await InstagramAccountingStore.shared.endActiveSession() {
            await AllowanceReminderService.shared.cancelReminder(for: session.id)
        }

        return .result()
    }
}
