import SwiftUI
import OmniFSCore

@main
struct OmniFSSettingsApp: App {
    var body: some Scene {
        WindowGroup("OmniFS Settings") {
            SettingsContainerView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 680, height: 560)
    }
}
