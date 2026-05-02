import Foundation

/// Broadcast whenever the relay charges the user for an AI call.
///
/// The credits meter lives server-side, so every AI response carries
/// `X-Cutti-Credits-*` headers. `OpenAIClient` forwards those through
/// `NotificationCenter` so any observer (primarily `RelaySession`) can
/// refresh its published state without the caller knowing about relay
/// plumbing.
///
/// We use Notification rather than direct calls into `RelaySession` so
/// the `Core/` layer stays free of UI dependencies — any piece of the app
/// that makes relay calls can emit one of these without wiring through
/// a shared singleton.
enum RelayCreditsNotification {
    static let name = Notification.Name("cutti.relay.credits.updated")

    /// Packed into `userInfo`. All fields optional — absent headers are
    /// reported as nil so the observer can decide whether to refresh.
    struct Payload {
        let charged: Int?
        let remaining: Int?
        let quota: Int?
        let periodResetAt: Date?
    }

    static let payloadKey = "payload"

    static func post(charged: Int?, remaining: Int?, quota: Int?, periodResetAt: Date?) {
        let payload = Payload(
            charged: charged,
            remaining: remaining,
            quota: quota,
            periodResetAt: periodResetAt
        )
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [payloadKey: payload]
        )
    }

    /// Parse any `X-Cutti-Credits-*` headers off an `HTTPURLResponse`
    /// and post a notification. Called by `OpenAIClient` on every relay
    /// response.
    static func postIfPresent(from response: HTTPURLResponse) {
        let headers = response.allHeaderFields
        func readInt(_ key: String) -> Int? {
            (headers[key] as? String).flatMap(Int.init)
                ?? (headers[key.lowercased()] as? String).flatMap(Int.init)
        }
        let charged = readInt("X-Cutti-Credits-Charged")
        let remaining = readInt("X-Cutti-Credits-Remaining")
        let quota = readInt("X-Cutti-Credits-Quota")
        let resetEpoch = readInt("X-Cutti-Period-Reset")
        guard charged != nil || remaining != nil || quota != nil else { return }
        let resetDate = resetEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        post(charged: charged, remaining: remaining, quota: quota, periodResetAt: resetDate)
    }
}
