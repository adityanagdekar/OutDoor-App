import AppIntents

struct StartInstagramSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Instagram Session"
    static let description = IntentDescription(
        "Starts or reuses an estimated Instagram usage session and returns whether access is available."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some ReturnsValue<Bool> {
        OutDoorLog.intent("START_INTENT_INVOKED")

        let result: InstagramSessionStartResult
        do {
            result = try await InstagramAccountingStore.shared.startSession()
        } catch {
            OutDoorLog.error("AppIntents", "START_INTENT_ACCOUNTING_FAILED error=\(error.localizedDescription)")
            throw error
        }

        OutDoorLog.intent(
            "START_INTENT_RESULT allowed=\(result.isAllowed) created=\(result.didCreateSession) sessionID=\(result.session?.id.uuidString ?? "none") remainingSeconds=\(result.remainingSeconds)"
        )

        if result.didCreateSession, let session = result.session {
            // Reminder delivery is optional; accounting remains valid when permission is denied.
            do {
                let scheduled = try await AllowanceReminderService.shared.scheduleReminder(
                    for: session
                )
                OutDoorLog.intent(
                    "START_INTENT_REMINDER_RESULT sessionID=\(session.id.uuidString) scheduled=\(scheduled)"
                )
            } catch {
                OutDoorLog.error(
                    "AppIntents",
                    "START_INTENT_REMINDER_FAILED sessionID=\(session.id.uuidString) error=\(error.localizedDescription)"
                )
            }
        }

        return .result(value: result.isAllowed)
    }
}
