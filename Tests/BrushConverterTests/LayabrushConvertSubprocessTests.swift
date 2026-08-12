@testable import BrushConverter
import BrushFormat
import Foundation
import Testing

@Suite("layabrush-convert subprocess")
struct LayabrushConvertSubprocessTests {
    @Test
    func dryConversionIsDeterministicAndReopensSavedOutput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("owned-source.data")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try SyntheticV1DiagnosticFixture.source(includeWet: false)
            .write(to: input)

        let first = try runCLI([
            "convert", "--json", "--output", output.path, input.path,
        ])
        #expect(first.status == LayabrushConvertExitStatus.success)
        #expect(first.standardError.isEmpty)
        let firstReport = try decodeReport(first.standardOutput)
        let document = try #require(
            firstReport.results.first?.documents.first
        )
        let outputPath = try #require(document.outputPath)
        let sourceHash = try ForeignBrushDocument.contentSHA256(
            Data(contentsOf: input)
        )
        #expect(
            URL(fileURLWithPath: outputPath).lastPathComponent
                == "synthetic-diagnostic-brush-"
                + "\(sourceHash.prefix(12)).layabrush"
        )
        let savedURL = URL(fileURLWithPath: outputPath)
        let firstBytes = try Data(contentsOf: savedURL)
        let package = try BrushPackageIO.load(from: savedURL)
        #expect(package.conversionReport == document.conversionReport)

        let second = try runCLI([
            "convert", "--json", "--replace", "--output", output.path,
            input.path,
        ])
        #expect(second.status == LayabrushConvertExitStatus.success)
        #expect(second.standardOutput == first.standardOutput)
        #expect(try Data(contentsOf: savedURL) == firstBytes)
    }

    @Test
    func wetConversionFailsAtTheNativeSchemaThreeBoundary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("wet-source")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try SyntheticV1DiagnosticFixture.source(includeWet: true)
            .write(to: input)

        let result = try runCLI([
            "convert", "--json", "--output", output.path, input.path,
        ])

        #expect(result.status == LayabrushConvertExitStatus.invalidInput)
        #expect(result.standardError.contains("mapping-failed"))
        let report = try decodeReport(result.standardOutput)
        let document = try #require(
            report.results.first?.documents.first
        )
        #expect(document.status == "failed")
        #expect(document.reasonCode == "mapping-failed")
        #expect(document.outputPath == nil)
        #expect(try layabrushFiles(in: output).isEmpty)
    }

    @Test
    func mixedBatchKeepsSuccessfulSiblingAndReturnsPartialFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid")
        let invalid = root.appendingPathComponent("invalid")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try SyntheticV1DiagnosticFixture.source(includeWet: false)
            .write(to: valid)
        try Data("not a brush".utf8).write(to: invalid)

        let result = try runCLI([
            "batch", "--json", "--output", output.path,
            valid.path, invalid.path,
        ])

        #expect(result.status == LayabrushConvertExitStatus.partialFailure)
        let report = try decodeReport(result.standardOutput)
        #expect(report.succeeded == 1)
        #expect(report.failed == 1)
        #expect(report.results.map(\.status) == ["converted", "failed"])
        #expect(try layabrushFiles(in: output).count == 1)
    }

    @Test
    func sourceBeyondPortableBudgetIsRejectedBeforeReading() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("oversized-source")
        #expect(FileManager.default.createFile(
            atPath: input.path,
            contents: nil
        ))
        let handle = try FileHandle(forWritingTo: input)
        try handle.truncate(
            atOffset: UInt64(
                BrushFormatLimits.maximumExpandedPackageBytes + 1
            )
        )
        try handle.close()

        let result = try runCLI(["inspect", "--json", input.path])

        #expect(result.status == LayabrushConvertExitStatus.invalidInput)
        #expect(result.standardError.contains("input-too-large"))
        let report = try decodeReport(result.standardOutput)
        #expect(report.results.first?.reasonCode == "input-too-large")
    }

    @Test
    func collisionPreservesExistingBytesUntilReplaceIsExplicit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try SyntheticV1DiagnosticFixture.source(includeWet: false)
            .write(to: input)

        let first = try runCLI([
            "convert", "--json", "--output", output.path, input.path,
        ])
        let firstReport = try decodeReport(first.standardOutput)
        let path = try #require(
            firstReport.results.first?.documents.first?.outputPath
        )
        let destination = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: destination)

        let collision = try runCLI([
            "convert", "--json", "--output", output.path, input.path,
        ])
        #expect(collision.status == LayabrushConvertExitStatus.outputFailure)
        #expect(collision.standardError.contains("output-exists"))
        #expect(try Data(contentsOf: destination) == original)
        #expect(try temporaryOutputFiles(in: output).isEmpty)

        let replacement = try runCLI([
            "convert", "--json", "--replace", "--output", output.path,
            input.path,
        ])
        #expect(replacement.status == LayabrushConvertExitStatus.success)
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test
    func failedOutputCreationLeavesNoPackageOrTemporaryFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source")
        let outputFile = root.appendingPathComponent("not-a-directory")
        try SyntheticV1DiagnosticFixture.source(includeWet: false)
            .write(to: input)
        try Data([1]).write(to: outputFile)

        let result = try runCLI([
            "convert", "--json", "--output", outputFile.path, input.path,
        ])

        #expect(result.status == LayabrushConvertExitStatus.outputFailure)
        #expect(try Data(contentsOf: outputFile) == Data([1]))
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(!contents.contains {
            $0.pathExtension == "layabrush"
                || $0.lastPathComponent.hasSuffix(".tmp")
        })
    }

    @Test
    func procreateInspectionWorksButConversionRequiresExplicitInputs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("extension-does-not-matter")
        let output = root.appendingPathComponent("output", isDirectory: true)
        let source = try ProcreateTestFixtureFactory.zip([
            .init(
                path: "Brush.archive",
                data: ProcreateTestFixtureFactory.brushArchive(
                    name: "Owned Structural Fixture",
                    unverifiedFields: ["spacing": 0.25]
                )
            ),
            .init(
                path: "Shape.png",
                data: ProcreateTestFixtureFactory.png
            ),
            .init(
                path: "Grain.png",
                data: ProcreateTestFixtureFactory.png
            ),
        ])
        try source.write(to: input)

        let inspection = try runCLI(["inspect", "--json", input.path])
        #expect(inspection.status == LayabrushConvertExitStatus.success)
        let inspectionReport = try decodeReport(inspection.standardOutput)
        let document = try #require(
            inspectionReport.results.first?.documents.first
        )
        #expect(document.inspection?.displayName
            == "Owned Structural Fixture")
        #expect(document.outputPath == nil)

        let conversion = try runCLI([
            "convert", "--json", "--output", output.path, input.path,
        ])
        #expect(conversion.status == LayabrushConvertExitStatus.invalidInput)
        #expect(
            conversion.standardError
                .contains("procreate-options-required")
        )
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: [
        "CC70504F-0D16-4D26-88A6-BF47BDA8ADE8",
        "21AF8C6B-3FB1-4BF8-8F89-F5768271DA35",
    ])
    func realProcreateTargetsConvertDeterministicallyAndReopen(
        identifier: String
    ) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = repositoryRoot()
        let source = repository.appendingPathComponent(
            "brushes/procreate/1_FREE_Charcoal_Set.brushset"
        )
        let substitutions = repository.appendingPathComponent(
            "brushes/procreate/substitutions.json"
        )
        let output = root.appendingPathComponent("output", isDirectory: true)
        let arguments = [
            "convert", "--json", "--brush", identifier,
            "--substitutions", substitutions.path,
            "--output", output.path, source.path,
        ]

        let first = try runCLI(arguments)
        #expect(first.status == LayabrushConvertExitStatus.success)
        let firstReport = try decodeReport(first.standardOutput)
        #expect(firstReport.succeeded == 1)
        #expect(firstReport.failed == 0)
        let document = try #require(firstReport.results.first?.documents.first)
        #expect(firstReport.results.first?.documents.count == 1)
        #expect(document.sourceBrushIdentifier == identifier)
        let outputPath = try #require(document.outputPath)
        let url = URL(fileURLWithPath: outputPath)
        let bytes = try Data(contentsOf: url)
        let package = try BrushPackageIO.load(from: url)
        #expect(package.definition.components.count == 2)
        #expect(package.conversionReport == document.conversionReport)

        let second = try runCLI(arguments.prefix(1) + ["--replace"] + arguments.dropFirst())
        #expect(second.status == LayabrushConvertExitStatus.success)
        #expect(try Data(contentsOf: url) == bytes)
    }
}

private struct CLIProcessResult {
    let status: Int32
    let standardOutput: Data
    let standardError: String
}

private func runCLI(_ arguments: [String]) throws -> CLIProcessResult {
    let executable = try layabrushConvertExecutable()
    let process = Process()
    let captureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("laya-cli-capture-\(UUID().uuidString)")
    let outputURL = captureRoot.appendingPathExtension("stdout")
    let errorURL = captureRoot.appendingPathExtension("stderr")
    #expect(FileManager.default.createFile(
        atPath: outputURL.path,
        contents: nil
    ))
    #expect(FileManager.default.createFile(
        atPath: errorURL.path,
        contents: nil
    ))
    defer {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: errorURL)
    }
    let output = try FileHandle(forWritingTo: outputURL)
    let error = try FileHandle(forWritingTo: errorURL)
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    try output.close()
    try error.close()
    let outputData = try Data(contentsOf: outputURL)
    let errorData = try Data(contentsOf: errorURL)
    return CLIProcessResult(
        status: process.terminationStatus,
        standardOutput: outputData,
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}

private func layabrushConvertExecutable() throws -> URL {
    let executable = Bundle.module.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("layabrush-convert")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw CLITestError.missingExecutable(executable.path)
    }
    return executable
}

private func decodeReport(_ data: Data) throws -> LayabrushConvertReport {
    try JSONDecoder().decode(LayabrushConvertReport.self, from: data)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "laya-cli-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    return directory
}

private func repositoryRoot() -> URL {
    var directory = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 3 {
        directory.deleteLastPathComponent()
    }
    return directory
}

private func layabrushFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }
    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "layabrush" }
}

private func temporaryOutputFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
}

private enum CLITestError: Error {
    case missingExecutable(String)
}
