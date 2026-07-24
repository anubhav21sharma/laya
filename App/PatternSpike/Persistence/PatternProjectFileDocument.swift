import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let patternProject = UTType(
        exportedAs: "com.anubhav.pattern-project",
        conformingTo: .zip
    )
}

struct PatternProjectFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.patternProject]

    let archiveData: Data

    init(archiveData: Data) {
        self.archiveData = archiveData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        archiveData = data
    }

    func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: archiveData)
    }
}
