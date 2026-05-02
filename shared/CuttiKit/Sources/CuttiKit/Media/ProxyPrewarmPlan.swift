import Foundation

/// Computes the set of proxy URLs to prewarm around a selected record.
///
/// Only includes records that are `.ready` and have a `proxyRelativePath`.
/// Records outside that window, non-ready records, or records with no proxy are skipped.
public enum ProxyPrewarmPlan {
    /// Returns absolute proxy URLs for records within `radius` positions of `selectedRecordID`.
    ///
    /// - Parameters:
    ///   - records: Ordered list of media asset records.
    ///   - selectedRecordID: The currently selected record's ID.
    ///   - projectRoot: Root URL used to resolve relative proxy paths.
    ///   - radius: Number of records before and after the selection to include.
    /// - Returns: Absolute file URLs for all warmed proxies, in list order.
    public static func urls(
        records: [MediaAssetRecord],
        selectedRecordID: UUID?,
        projectRoot: URL?,
        radius: Int
    ) -> [URL] {
        guard let selectedRecordID,
              let projectRoot,
              let selectedIndex = records.firstIndex(where: { $0.id == selectedRecordID }) else {
            return []
        }

        let lowerBound = max(0, selectedIndex - radius)
        let upperBound = min(records.count - 1, selectedIndex + radius)

        return records[lowerBound...upperBound].compactMap { record in
            guard record.status == .ready,
                  let proxyRelativePath = record.derived.proxyRelativePath else {
                return nil
            }
            return projectRoot.appending(path: proxyRelativePath)
        }
    }
}
