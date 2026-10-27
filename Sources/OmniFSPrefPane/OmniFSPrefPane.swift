import Cocoa
import PreferencePanes
import SwiftUI
import OmniFSCore

@objc(OmniFSPrefPane)
@MainActor
public class OmniFSPrefPane: NSPreferencePane {

    public override func loadMainView() -> NSView {
        let hostingView = NSHostingView(rootView: SettingsContainerView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hostingView.autoresizingMask = [.width, .height]
        self.mainView = hostingView
        return hostingView
    }

    public override func mainViewDidLoad() {
        super.mainViewDidLoad()
    }
}
