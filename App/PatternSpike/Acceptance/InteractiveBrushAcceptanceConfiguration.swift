import Foundation

struct InteractiveBrushAcceptanceConfiguration: Equatable, Sendable {
    let logURL: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["INTERACTIVE_BRUSH_ACCEPTANCE_LOG"],
              !path.isEmpty,
              NSString(string: path).isAbsolutePath
        else {
            logURL = nil
            return
        }
        logURL = URL(fileURLWithPath: path, isDirectory: false)
    }
}
