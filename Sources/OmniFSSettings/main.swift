import SwiftUI
import OmniFSCore

@main
struct OmniFSSettingsApp: App {
    var body: some Scene {
        WindowGroup("OmniFS Settings") {
            SettingsContainerView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
