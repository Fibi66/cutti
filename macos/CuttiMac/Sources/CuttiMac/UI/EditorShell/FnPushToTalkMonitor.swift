import AppKit
import SwiftUI

/// Hosts an `NSEvent` local monitor for `flagsChanged` so the user can
/// hold **Fn** to push-to-talk into the AI chat composer — same
/// interaction model as Veery's hold-Right-Cmd, adapted for Fn.
///
/// The monitor is local (not global), so it only fires while Cutti is
/// the active app. That means we do **not** need Input Monitoring
/// permission, and Fn continues to work normally for OS shortcuts in
/// other apps.
///
/// State-machine detail: `.function` also shows up in `modifierFlags`
/// on arrow / page / home / end keypresses on external keyboards, but
/// those events are `.keyDown`, not `.flagsChanged`. A real Fn key
/// press/release on the built-in keyboard emits `.flagsChanged`. So
/// we only listen to flagsChanged and track rising/falling edges of
/// the `.function` bit.
@MainActor
final class FnPushToTalkMonitor: ObservableObject {
    private var monitor: Any?
    private var fnDown = false

    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let fnNow = event.modifierFlags.contains(.function)
            // Ignore edges where a modifier other than Fn is involved —
            // we only care about the physical Fn key, not Fn-being-set
            // as a side-effect of Cmd/Option/Shift chords.
            let otherModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if !otherModifiers.isEmpty {
                return event
            }

            if fnNow && !self.fnDown {
                self.fnDown = true
                self.onBegin()
            } else if !fnNow && self.fnDown {
                self.fnDown = false
                self.onEnd()
            }
            return event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        // If we disappear mid-hold, pretend the key came up so downstream
        // recorders don't get stuck in the recording state.
        if fnDown {
            fnDown = false
            onEnd()
        }
    }
}
