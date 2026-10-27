import Cocoa
@preconcurrency import PreferencePanes
import SwiftUI
import OmniFSCore

@MainActor
private final class PrefPaneHostingView: NSHostingView<SettingsContainerView> {
    override var fittingSize: NSSize {
        NSSize(width: 380, height: super.fittingSize.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        var frame = window.frame
        let targetWidth: CGFloat = 380
        if frame.size.width != targetWidth {
            frame.origin.x += (frame.size.width - targetWidth) / 2
            frame.size.width = targetWidth
            window.setFrame(frame, display: true, animate: false)
        }
        window.minSize = NSSize(width: targetWidth, height: 460)
        window.maxSize = NSSize(width: targetWidth, height: 1200)
    }
}

@objc(OmniFSPrefPane)
public class OmniFSPrefPane: NSPreferencePane {

    public override func loadMainView() -> NSView {
        let view = MainActor.assumeIsolated {
            let hostingView = PrefPaneHostingView(rootView: SettingsContainerView())
            hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
            hostingView.autoresizingMask = [.height]
            return hostingView as NSView
        }
        self.mainView = view
        return view
    }

    public override func mainViewDidLoad() {
        super.mainViewDidLoad()
    }
}



