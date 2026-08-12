import SwiftUI

@main
struct PatternSpikeApp: App {
    init() {
        #if HARNESS_BUILD
        HarnessLaunch.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            #if os(macOS)
            EditorFocusedCommands()
            #endif
            #if DEBUG
            BrushLabCommands()
            #endif
        }

        #if DEBUG
        WindowGroup("Brush Lab", id: "brush-lab") {
            BrushLabView()
        }
        #endif
    }
}
