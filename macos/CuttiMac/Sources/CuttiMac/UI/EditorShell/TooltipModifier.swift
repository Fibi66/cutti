import SwiftUI
import AppKit

// Why this file had to be rewritten multiple times:
//
//   1. SwiftUI's .help() — broken on borderless Menus and disabled
//      Buttons (our timeline toolbar is nothing but those).
//   2. NSView in .background + NSView.toolTip — SwiftUI renders the
//      button label on top, hover never reaches AppKit.
//   3. Pure SwiftUI .onHover bubble — .onHover does not fire on
//      disabled Buttons, and most of our icons are disabled before
//      media is imported.
//   4. NSView in .overlay with hitTest=nil — NSToolTipManager skips
//      views that opt out of hit testing, so it never registers the
//      tooltip.
//
// What finally works: host the SwiftUI content inside an NSHostingView,
// set .toolTip on that hosting NSView directly, and put it into SwiftUI
// via NSViewRepresentable. This is exactly how native NSButton tooltips
// work — the NSView owns the tooltip rect, and AppKit displays the
// tooltip whenever the mouse lingers in its bounds, completely
// independent of SwiftUI's hit-testing, disabled state, or control
// style. Clicks route into the hosted SwiftUI content normally because
// NSHostingView forwards events to the SwiftUI view tree it contains.
extension View {
    func tooltip(_ text: String) -> some View {
        TooltipContainer(text: text, content: self)
    }
}

private struct TooltipContainer<Content: View>: NSViewRepresentable {
    let text: String
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.toolTip = text
        // Let NSHostingView size itself to its SwiftUI content so the
        // tooltip rect matches what the user sees and clicks on.
        host.translatesAutoresizingMaskIntoConstraints = false
        host.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        host.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return host
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content
        if nsView.toolTip != text {
            nsView.toolTip = text
        }
    }

    // Report the hosting view's intrinsic SwiftUI size so parents lay
    // us out correctly; without this the container can collapse to
    // zero and the tooltip rect would be empty.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        return fitting == .zero ? nil : fitting
    }
}
