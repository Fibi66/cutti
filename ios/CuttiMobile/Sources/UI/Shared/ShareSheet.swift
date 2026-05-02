import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around `UIActivityViewController` so we can
/// hand the exported file to Messages / AirDrop / Files / any app
/// that accepts a `public.movie`.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var activities: [UIActivity]? = nil
    var excluded: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: activities)
        vc.excludedActivityTypes = excluded
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
