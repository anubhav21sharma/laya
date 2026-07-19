import SwiftUI

@main
struct PatternSpikeApp: App {
    init() {
        HarnessLaunch.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
