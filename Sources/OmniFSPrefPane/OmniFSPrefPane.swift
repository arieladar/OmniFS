import Cocoa
@preconcurrency import PreferencePanes
import SwiftUI
import OmniFSCore

@MainActor
private final class PrefPaneHostingView: NSHostingView<SettingsContainerView> {
    required init(rootView: SettingsContainerView) {
        super.init(rootView: rootView)
        self.autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        self.autoresizingMask = [.width, .height]
    }
}

@objc(OmniFSPrefPane)
public class OmniFSPrefPane: NSPreferencePane {

    public override func loadMainView() -> NSView {
        let view = MainActor.assumeIsolated {
            let hostingView = PrefPaneHostingView(rootView: SettingsContainerView())
            hostingView.autoresizingMask = [.width, .height]
            return hostingView as NSView
        }
        self.mainView = view
        return view
    }

    public override func mainViewDidLoad() {
        super.mainViewDidLoad()
    }
}
