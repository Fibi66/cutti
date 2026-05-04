import Foundation
import IOKit
#if canImport(AppKit)
import AppKit
#endif

/// User-authored body of a bug report, plus optional auto-collected
/// diagnostics. Encoded to JSON and posted to the relay's `/feedback`
/// endpoint, which is responsible for opening a GitHub issue (server
/// side detail — not in this repo).
struct BugReport: Codable, Sendable, Equatable {
    var description: String
    var reproSteps: String
    var contactEmail: String
    /// Omitted from the encoded payload when `nil` — i.e. the user
    /// toggled "Include diagnostics" off. The server treats an absent
    /// `diagnostics` field as an explicit opt-out.
    var diagnostics: BugReportDiagnostics?
}

/// Auto-collected, opt-in environment metadata. Everything in here is
/// shown to the user verbatim before submission so there are no
/// surprises. Username paths in any string field are sanitized before
/// the report leaves the process — see `Self.sanitize(_:)`.
///
/// Account identity is deliberately **not** in this struct. When the
/// user is signed in, the relay derives their account ID from the
/// `Authorization: Bearer …` JWT — sending it in the body too would
/// risk leaking it into the public GitHub issue if the server-side
/// projection is ever sloppy. Diagnostics-as-sent contains nothing
/// that needs server-side scrubbing before publication.
struct BugReportDiagnostics: Codable, Sendable, Equatable {
    let appName: String
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let hardwareModel: String
    let physicalMemoryGB: Int
    let locale: String
    let timezone: String
    let submittedAt: String

    /// Snapshots the current process / environment. Safe to call from
    /// any actor — only reads system properties, no I/O of consequence.
    static func current(now: Date = Date()) -> BugReportDiagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        let appName = (info["CFBundleName"] as? String) ?? "cutti"
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let appBuild = (info["CFBundleVersion"] as? String) ?? "0"
        let memoryGB = Int(round(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return BugReportDiagnostics(
            appName: appName,
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.readHardwareModel(),
            physicalMemoryGB: memoryGB,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            submittedAt: formatter.string(from: now)
        )
    }

    /// Replaces `/Users/<anything>/` with `/Users/<user>/` so a real
    /// macOS username doesn't leak into the report. Conservative —
    /// matches any non-empty path segment after `/Users/` rather than
    /// hardcoding the current `NSUserName()`, which would miss other
    /// accounts referenced in stack traces or paths the user pasted
    /// into the description.
    static func sanitize(_ value: String) -> String {
        let pattern = #"/Users/[^/\s\"]+/"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "/Users/<user>/"
        )
    }

    /// Reads the marketing model identifier (e.g. `MacBookPro18,3`)
    /// via sysctl. Falls back to `"unknown"` if anything goes wrong —
    /// hardware model is nice-to-have for triage, not load-bearing.
    private static func readHardwareModel() -> String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        let status = sysctlbyname("hw.model", &bytes, &size, nil, 0)
        guard status == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}

/// Server-side response shape. Both fields optional because the relay
/// may degrade gracefully — e.g. it stored the report but the GitHub
/// API is rate-limited at that moment, in which case `issueURL` is
/// nil but `ticketID` is still set. UI tolerates either being missing.
struct BugReportSubmissionResponse: Codable, Sendable, Equatable {
    let issueURL: String?
    let ticketID: String?
}

enum BugReportError: Error, LocalizedError, Equatable {
    case validation(String)
    case payloadTooLarge(actualBytes: Int, limitBytes: Int)
    case rateLimited(retryAfterSeconds: Int)
    case server(status: Int, message: String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .validation(let msg):
            return msg
        case .payloadTooLarge(let actual, let limit):
            return L("Report is too large (%d KB, limit %d KB). Please trim the description or steps.", actual / 1024, limit / 1024)
        case .rateLimited(let retry):
            return L("Too many reports. Please try again in about %d seconds.", retry)
        case .server:
            // Server-provided text is a developer diagnostic — never
            // surface it (or the HTTP status) to the user. A generic
            // localized line is enough; details are still in the logs.
            return L("Couldn't submit the bug report right now. Please try again in a moment.")
        case .network:
            return L("Network error. Please check your connection and try again.")
        }
    }
}

/// Posts bug reports to the cutti relay. The relay is responsible for
/// turning the request into a GitHub issue + dashboard entry; this
/// type only knows about HTTP.
///
/// `actor`-isolated so concurrent submit attempts (user double-clicks
/// Submit) are serialised. An additional `isSubmitting` flag rejects
/// a second submit that arrives while the first is still in flight,
/// since serialisation alone would still post both reports back-to-back.
actor BugReportService {
    static let shared = BugReportService()

    /// Cap on the description body itself. Keeps abuse manageable on
    /// the server side — a real bug report fits comfortably.
    static let maxDescriptionBytes = 10_000
    /// Cap on repro steps body.
    static let maxReproBytes = 5_000
    /// Hard ceiling on the encoded JSON payload regardless of how the
    /// 10 KB / 5 KB / diagnostics split out — defence-in-depth against
    /// a future change accidentally inflating the body.
    static let maxPayloadBytes = 64 * 1024

    private let baseURL: URL
    private let session: URLSession
    private let pathPrefix: String
    private var isSubmitting: Bool = false

    init(
        baseURLString: String = RelayClient.relayBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = URL(string: baseURLString) ?? URL(string: "https://api.cutti.app")!
        self.session = session
        self.pathPrefix = "/v1/feedback"
    }

    /// Submit a report. Throws `BugReportError` on validation failure,
    /// over-size payload, network failure, or non-2xx response.
    /// A second submit that arrives while a previous one is in flight
    /// is rejected with `.validation` rather than serialising — we'd
    /// rather the user see a clear "already submitting" message than
    /// silently end up with duplicate GitHub issues.
    @discardableResult
    func submit(_ report: BugReport) async throws -> BugReportSubmissionResponse {
        if isSubmitting {
            throw BugReportError.validation(
                "A bug report is already being submitted. Please wait for it to finish."
            )
        }
        isSubmitting = true
        defer { isSubmitting = false }

        try Self.validate(report)
        let body = try Self.encode(report)
        guard body.count <= Self.maxPayloadBytes else {
            throw BugReportError.payloadTooLarge(
                actualBytes: body.count,
                limitBytes: Self.maxPayloadBytes
            )
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(pathPrefix))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("cutti/\(report.diagnostics?.appVersion ?? Self.cachedAppVersion)",
                         forHTTPHeaderField: "User-Agent")
        if let jwt = RelaySession.currentBearerToken(), !jwt.isEmpty {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BugReportError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BugReportError.network("Server returned a non-HTTP response.")
        }
        if http.statusCode == 429 {
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw BugReportError.rateLimited(retryAfterSeconds: retry)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BugReportError.server(
                status: http.statusCode,
                message: String(message.prefix(500))
            )
        }

        // Accept missing / partial bodies as success — relay degrading
        // gracefully is fine; UI just shows a generic confirmation.
        if data.isEmpty {
            return BugReportSubmissionResponse(issueURL: nil, ticketID: nil)
        }
        return (try? JSONDecoder().decode(BugReportSubmissionResponse.self, from: data))
            ?? BugReportSubmissionResponse(issueURL: nil, ticketID: nil)
    }

    /// Returns the exact JSON the server will receive, pretty-printed
    /// for the "Show what will be sent" disclosure. Pure: no network.
    nonisolated static func previewJSON(for report: BugReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sanitized(report)),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    // MARK: - Internal helpers (visible to tests)

    static func validate(_ report: BugReport) throws {
        let trimmed = report.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else {
            throw BugReportError.validation(
                "Please describe what went wrong (at least 10 characters)."
            )
        }
        guard report.description.utf8.count <= maxDescriptionBytes else {
            throw BugReportError.validation(
                "Description is too long (limit \(maxDescriptionBytes / 1024) KB)."
            )
        }
        guard report.reproSteps.utf8.count <= maxReproBytes else {
            throw BugReportError.validation(
                "Steps to reproduce are too long (limit \(maxReproBytes / 1024) KB)."
            )
        }
        if !report.contactEmail.isEmpty {
            // Cheap syntactic check — server does the real validation.
            // Just guard against accidentally sending a paragraph here.
            let candidate = report.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.contains("@"), candidate.count < 200 else {
                throw BugReportError.validation("Contact email looks invalid.")
            }
        }
    }

    static func encode(_ report: BugReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sanitized(report))
    }

    /// Applies `BugReportDiagnostics.sanitize` to every free-text
    /// field that could plausibly contain a user-path. Diagnostics
    /// fields are already either non-textual or set by us, so they
    /// don't need scrubbing.
    static func sanitized(_ report: BugReport) -> BugReport {
        var copy = report
        copy.description = BugReportDiagnostics.sanitize(report.description)
        copy.reproSteps = BugReportDiagnostics.sanitize(report.reproSteps)
        return copy
    }

    /// Read once at startup and reused for the `User-Agent` header so
    /// `submit()` doesn't have to spin up the full `current()` snapshot
    /// when the user opted out of diagnostics.
    private static let cachedAppVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
}
