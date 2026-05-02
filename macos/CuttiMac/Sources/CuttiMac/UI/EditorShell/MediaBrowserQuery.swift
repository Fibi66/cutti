import Foundation
import CuttiKit

enum MediaBrowserQuery {
    static func filter(records: [MediaAssetRecord], query: String) -> [MediaAssetRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }

        let needle = trimmed.lowercased()

        return records.filter { record in
            MediaRecordPresentation.title(for: record).lowercased().contains(needle) ||
            MediaRecordPresentation.statusText(for: record.status).lowercased().contains(needle) ||
            (record.copilot?.semanticTags.contains { $0.lowercased().contains(needle) } == true)
        }
    }
}
