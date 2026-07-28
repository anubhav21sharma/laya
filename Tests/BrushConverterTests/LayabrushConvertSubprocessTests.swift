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
    func wetConversionSavesBlockedIntentAndEmitsDiagnostic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("wet-source")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try SyntheticV1DiagnosticFixture.source(includeWet: true)
            .write(to: input)

        let result = try runCLI([
            "convert", "--json", "--output", output.path, input.path,
        ])

        #expect(result.status == LayabrushConvertExitStatus.success)
        #expect(result.standardError.contains("unsupported"))
        #expect(result.standardError.contains(SyntheticV1SemanticKeys.wet))
        let report = try decodeReport(result.standardOutput)
        let outputPath = try #require(
            report.results.first?.documents.first?.outputPath
        )
        let package = try BrushPackageIO.load(
            from: URL(fileURLWithPath: outputPath)
        )
        #expect(
            package.definition.compatibility.requiredSemanticKeys
                == [SyntheticV1SemanticKeys.wet]
        )
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
    func procreateInspectionWorksButConversionRequiresVerifiedMapper() throws {
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
                .contains("no-verified-semantic-mapper")
        )
        #expect(!FileManager.default.fileExists(atPath: output.path))
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
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    return CLIProcessResult(
        status: process.terminationStatus,
        standardOutput: outputData,
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}

private func layabrushConvertExecutable() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 3 {
        directory.deleteLastPathComponent()
    }
    let executable = directory
        .appendingPathComponent(".build/debug/layabrush-convert")
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
