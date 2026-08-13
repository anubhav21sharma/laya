import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let patternProject = UTType(
        exportedAs: "com.anubhav.pattern-project",
        conformingTo: .zip
    )
}

struct StagedEditorExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.patternProject, .png]

    let data: Data

    init(stagedFileURL: URL) throws {
        data = try Data(contentsOf: stagedFileURL)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration _: WriteConfiguration) throws
        -> FileWrapper
    {
        FileWrapper(regularFileWithContents: data)
    }
}
