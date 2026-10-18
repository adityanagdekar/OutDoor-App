import AppIntents

struct EndInstagramSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "End Instagram Session"
    static let description = IntentDescription(
        "Finalizes the active estimated Instagram usage session without opening OutDoor."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        OutDoorLog.intent("END_INTENT_INVOKED")

        do {
            if let session = try await InstagramAccountingStore.shared.endActiveSession() {
                OutDoorLog.intent(
                    "END_INTENT_FINALIZED sessionID=\(session.id.uuidString) elapsedSeconds=\(session.elapsedSeconds ?? 0) consumedSeconds=\(session.consumedSeconds ?? 0) excessSeconds=\(session.excessSeconds ?? 0)"
                )
                await AllowanceReminderService.shared.cancelReminder(for: session.id)
            } else {
                OutDoorLog.intent("END_INTENT_NO_ACTIVE_SESSION")
            }
        } catch {
            OutDoorLog.error("AppIntents", "END_INTENT_FAILED error=\(error.localizedDescription)")
            throw error
        }

        return .result()
    }
}
