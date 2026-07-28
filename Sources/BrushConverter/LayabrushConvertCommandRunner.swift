import BrushFormat
import Foundation

public struct LayabrushConvertCommandOutput: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum LayabrushConvertExitStatus {
    public static let success: Int32 = 0
    public static let partialFailure: Int32 = 1
    public static let usage: Int32 = 64
    public static let invalidInput: Int32 = 65
    public static let missingInput: Int32 = 66
    public static let internalFailure: Int32 = 70
    public static let outputFailure: Int32 = 73
    public static let inputOutputFailure: Int32 = 74
}

public struct LayabrushConvertReport: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let command: String
    public let results: [LayabrushConvertInputResult]
    public let succeeded: Int
    public let failed: Int
}

public struct LayabrushConvertInputResult: Codable, Equatable, Sendable {
    public let inputPath: String
    public let status: String
    public let reasonCode: String?
    public let parserIdentifier: String?
    public let documents: [LayabrushConvertDocumentResult]
}

public struct LayabrushConvertDocumentResult:
    Codable, Equatable, Sendable
{
    public let sourceBrushIdentifier: String
    public let displayName: String
    public let status: String
    public let reasonCode: String?
    public let outputPath: String?
    public let inspection: ForeignBrushIR?
    public let conversionReport: BrushConversionReport?
}

public enum LayabrushConvertCommandRunner {
    public static let usage =
        """
        usage:
          layabrush-convert diagnostic synthetic-v1 <dry|wet>
          layabrush-convert probe [--json] <input>...
          layabrush-convert inspect [--json] <input>...
          layabrush-convert convert [--json] [--replace] [--output <directory>] <input>
          layabrush-convert batch [--json] [--replace] [--output <directory>] <input>...
        """
        + "\n"

    public static func run(
        arguments: [String]
    ) -> LayabrushConvertCommandOutput {
        if arguments.first == "diagnostic" {
            return runDiagnostic(arguments: arguments) {
                try SyntheticV1DiagnosticRunner.run(scenario: $0)
            }
        }
        guard let invocation = Invocation(arguments: arguments) else {
            return output(
                status: LayabrushConvertExitStatus.usage,
                standardError: usage
            )
        }
        return execute(invocation)
    }

    static func run(
        arguments: [String],
        execute: (SyntheticV1DiagnosticScenario) throws
            -> SyntheticV1DiagnosticResult
    ) -> LayabrushConvertCommandOutput {
        runDiagnostic(arguments: arguments, execute: execute)
    }

    private static func runDiagnostic(
        arguments: [String],
        execute: (SyntheticV1DiagnosticScenario) throws
            -> SyntheticV1DiagnosticResult
    ) -> LayabrushConvertCommandOutput {
        guard arguments.count == 3,
              arguments[0] == "diagnostic",
              arguments[1] == "synthetic-v1",
              let scenario = SyntheticV1DiagnosticScenario(
                  rawValue: arguments[2]
              )
        else {
            return output(
                status: LayabrushConvertExitStatus.usage,
                standardError: usage
            )
        }

        do {
            return try jsonOutput(
                execute(scenario),
                status: LayabrushConvertExitStatus.success
            )
        } catch let failure as SyntheticV1DiagnosticFailure {
            return diagnosticFailure(stage: failure.stage)
        } catch {
            return diagnosticFailure(stage: .fixture)
        }
    }

    private static func execute(
        _ invocation: Invocation
    ) -> LayabrushConvertCommandOutput {
        var results = [LayabrushConvertInputResult]()
        var diagnostics = [String]()
        var claimedOutputPaths = Set<String>()
        for input in invocation.inputs {
            let result = process(
                input: input,
                invocation: invocation,
                diagnostics: &diagnostics,
                claimedOutputPaths: &claimedOutputPaths
            )
            results.append(result)
        }
        let counts = resultCounts(
            results,
            command: invocation.command
        )
        let report = LayabrushConvertReport(
            schemaVersion: 1,
            command: invocation.command.rawValue,
            results: results,
            succeeded: counts.succeeded,
            failed: counts.failed
        )
        let status: Int32 = if counts.failed == 0 {
            LayabrushConvertExitStatus.success
        } else if counts.succeeded > 0 {
            LayabrushConvertExitStatus.partialFailure
        } else {
            failureStatus(for: results)
        }
        var standardError = diagnostics.joined()
        if invocation.json {
            do {
                return try jsonOutput(
                    report,
                    status: status,
                    standardError: standardError
                )
            } catch {
                return output(
                    status: LayabrushConvertExitStatus.internalFailure,
                    standardError:
                    standardError
                        + "layabrush-convert: json-encoding-failed\n"
                )
            }
        }
        standardError += humanReport(results)
        let summary =
            "layabrush-convert: \(invocation.command.rawValue): "
                + "\(counts.succeeded) succeeded, \(counts.failed) failed\n"
        return output(
            status: status,
            standardError: standardError + summary
        )
    }

    private static func process(
        input: String,
        invocation: Invocation,
        diagnostics: inout [String],
        claimedOutputPaths: inout Set<String>
    ) -> LayabrushConvertInputResult {
        let source: Data
        do {
            source = try readSource(input)
        } catch let error as InputReadError {
            let reason = error.reasonCode
            diagnostics.append(diagnostic(reason, input))
            return failedInput(input, reason: reason)
        } catch {
            diagnostics.append(diagnostic("input-io-failed", input))
            return failedInput(input, reason: "input-io-failed")
        }

        let selection: ParserSelection
        do {
            guard let selected = try selectParser(source) else {
                diagnostics.append(diagnostic("unrecognized-format", input))
                return failedInput(input, reason: "unrecognized-format")
            }
            selection = selected
        } catch {
            diagnostics.append(diagnostic("invalid-foreign-data", input))
            return failedInput(input, reason: "invalid-foreign-data")
        }

        if invocation.command == .probe {
            return LayabrushConvertInputResult(
                inputPath: input,
                status: "probed",
                reasonCode: nil,
                parserIdentifier: selection.identifier,
                documents: []
            )
        }

        let documents: [ForeignBrushDocument]
        do {
            documents = try selection.parse(source)
            guard !documents.isEmpty else {
                diagnostics.append(diagnostic("no-brushes-found", input))
                return failedInput(
                    input,
                    reason: "no-brushes-found",
                    parserIdentifier: selection.identifier
                )
            }
        } catch {
            diagnostics.append(diagnostic("parse-failed", input))
            return failedInput(
                input,
                reason: "parse-failed",
                parserIdentifier: selection.identifier
            )
        }

        for document in documents {
            appendDiagnostics(
                document.ir.diagnostics,
                input: input,
                diagnostics: &diagnostics
            )
        }
        if invocation.command == .inspect {
            return LayabrushConvertInputResult(
                inputPath: input,
                status: "inspected",
                reasonCode: nil,
                parserIdentifier: selection.identifier,
                documents: documents.map {
                    LayabrushConvertDocumentResult(
                        sourceBrushIdentifier:
                        $0.ir.sourceBrushIdentifier,
                        displayName: $0.ir.displayName,
                        status: "inspected",
                        reasonCode: nil,
                        outputPath: nil,
                        inspection: $0.ir,
                        conversionReport: nil
                    )
                }
            )
        }

        var documentResults = [LayabrushConvertDocumentResult]()
        for document in documents {
            documentResults.append(
                convert(
                    document,
                    selection: selection,
                    input: input,
                    invocation: invocation,
                    diagnostics: &diagnostics,
                    claimedOutputPaths: &claimedOutputPaths
                )
            )
        }
        let inputFailed = documentResults.contains {
            $0.status == "failed"
        }
        let firstFailure = documentResults.first {
            $0.status == "failed"
        }?.reasonCode
        return LayabrushConvertInputResult(
            inputPath: input,
            status: inputFailed ? "failed" : "converted",
            reasonCode: firstFailure,
            parserIdentifier: selection.identifier,
            documents: documentResults
        )
    }

    private static func convert(
        _ document: ForeignBrushDocument,
        selection: ParserSelection,
        input: String,
        invocation: Invocation,
        diagnostics: inout [String],
        claimedOutputPaths: inout Set<String>
    ) -> LayabrushConvertDocumentResult {
        let mapped: ForeignBrushMappingResult
        do {
            mapped = try selection.map(document)
        } catch ParserSelectionError.noVerifiedMapper {
            diagnostics.append(diagnostic(
                "no-verified-semantic-mapper",
                "\(input):\(document.ir.sourceBrushIdentifier)"
            ))
            return failedDocument(
                document,
                reason: "no-verified-semantic-mapper"
            )
        } catch {
            diagnostics.append(diagnostic(
                "mapping-failed",
                "\(input):\(document.ir.sourceBrushIdentifier)"
            ))
            return failedDocument(document, reason: "mapping-failed")
        }

        appendDiagnostics(
            mapped.report.diagnostics,
            input: input,
            diagnostics: &diagnostics
        )
        for entry in mapped.report.entries
            where entry.disposition == .unsupported
        {
            diagnostics.append(
                "layabrush-convert: unsupported: \(input):"
                    + "\(entry.sourceSemanticKey): \(entry.reasonCode)\n"
            )
        }

        let destination = outputURL(
            for: document,
            directory: invocation.outputDirectory
        )
        guard claimedOutputPaths.insert(destination.path).inserted else {
            diagnostics.append(diagnostic(
                "output-name-collision",
                destination.path
            ))
            return failedDocument(
                document,
                reason: "output-name-collision"
            )
        }
        if !invocation.replace,
           FileManager.default.fileExists(atPath: destination.path)
        {
            diagnostics.append(diagnostic("output-exists", destination.path))
            return failedDocument(document, reason: "output-exists")
        }
        do {
            try FileManager.default.createDirectory(
                at: invocation.outputDirectory,
                withIntermediateDirectories: true
            )
            try BrushPackageIO.save(
                mapped.package,
                to: destination,
                replacingExisting: invocation.replace
            )
            let reopened = try BrushPackageIO.load(from: destination)
            guard reopened == mapped.package else {
                throw ConversionWriteError.reopenMismatch
            }
        } catch {
            diagnostics.append(diagnostic("output-write-failed", destination.path))
            return failedDocument(document, reason: "output-write-failed")
        }
        return LayabrushConvertDocumentResult(
            sourceBrushIdentifier: document.ir.sourceBrushIdentifier,
            displayName: document.ir.displayName,
            status: "converted",
            reasonCode: nil,
            outputPath: destination.path,
            inspection: nil,
            conversionReport: mapped.report
        )
    }

    private static func outputURL(
        for document: ForeignBrushDocument,
        directory: URL
    ) -> URL {
        let name = sanitizedName(document.ir.displayName)
        let sourceHash = document.ir.provenance.sourceContentSHA256.prefix(12)
        return directory.appendingPathComponent(
            "\(name)-\(sourceHash).layabrush",
            isDirectory: false
        )
    }

    private static func sanitizedName(_ name: String) -> String {
        var result = [UInt8]()
        var pendingSeparator = false
        for byte in name.lowercased().utf8 {
            let accepted =
                (97 ... 122).contains(byte)
                    || (48 ... 57).contains(byte)
            if accepted {
                if pendingSeparator, !result.isEmpty {
                    result.append(45)
                }
                result.append(byte)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
            if result.count >= 72 {
                break
            }
        }
        while result.last == 45 {
            result.removeLast()
        }
        return result.isEmpty ? "brush" : String(decoding: result, as: UTF8.self)
    }

    private static func readSource(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
            ])
        } catch {
            throw InputReadError.missing
        }
        guard values.isRegularFile == true else {
            throw InputReadError.missing
        }
        guard let fileSize = values.fileSize,
              fileSize <= 512 * 1024 * 1024
        else {
            throw InputReadError.tooLarge
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 512 * 1024 * 1024 else {
                throw InputReadError.tooLarge
            }
            return data
        } catch let error as InputReadError {
            throw error
        } catch {
            throw InputReadError.io
        }
    }

    private static func selectParser(
        _ source: Data
    ) throws -> ParserSelection? {
        let synthetic = SyntheticV1BrushParser()
        if try synthetic.probe(source) {
            return .synthetic
        }
        let procreate = ProcreateBrushParser()
        if try procreate.probe(source) {
            return .procreate
        }
        return nil
    }

    private static func appendDiagnostics(
        _ values: [ForeignBrushDiagnostic],
        input: String,
        diagnostics: inout [String]
    ) {
        for value in values {
            diagnostics.append(
                "layabrush-convert: \(value.severity.rawValue): \(input):"
                    + "\(value.code): \(value.message)\n"
            )
        }
    }

    private static func appendDiagnostics(
        _ values: [BrushConversionDiagnostic],
        input: String,
        diagnostics: inout [String]
    ) {
        for value in values {
            diagnostics.append(
                "layabrush-convert: \(value.severity.rawValue): \(input):"
                    + "\(value.code): \(value.message)\n"
            )
        }
    }

    private static func diagnostic(_ code: String, _ path: String) -> String {
        "layabrush-convert: \(code): \(path)\n"
    }

    private static func humanReport(
        _ results: [LayabrushConvertInputResult]
    ) -> String {
        var lines = [String]()
        for result in results {
            let parser = result.parserIdentifier
                .map { " parser=\($0)" }
                ?? ""
            lines.append(
                "\(result.status): \(result.inputPath)\(parser)\n"
            )
            for document in result.documents {
                let output = document.outputPath
                    .map { " output=\($0)" }
                    ?? ""
                lines.append(
                    "  \(document.status): "
                        + "\(document.displayName)\(output)\n"
                )
            }
        }
        return lines.joined()
    }

    private static func failedInput(
        _ input: String,
        reason: String,
        parserIdentifier: String? = nil
    ) -> LayabrushConvertInputResult {
        LayabrushConvertInputResult(
            inputPath: input,
            status: "failed",
            reasonCode: reason,
            parserIdentifier: parserIdentifier,
            documents: []
        )
    }

    private static func failedDocument(
        _ document: ForeignBrushDocument,
        reason: String
    ) -> LayabrushConvertDocumentResult {
        LayabrushConvertDocumentResult(
            sourceBrushIdentifier: document.ir.sourceBrushIdentifier,
            displayName: document.ir.displayName,
            status: "failed",
            reasonCode: reason,
            outputPath: nil,
            inspection: nil,
            conversionReport: nil
        )
    }

    private static func failureStatus(
        for results: [LayabrushConvertInputResult]
    ) -> Int32 {
        let reasons = Set(
            results.compactMap(\.reasonCode)
                + results.flatMap(\.documents).compactMap(\.reasonCode)
        )
        if reasons == ["input-missing"] {
            return LayabrushConvertExitStatus.missingInput
        }
        if reasons.contains("output-exists")
            || reasons.contains("output-name-collision")
            || reasons.contains("output-write-failed")
            || reasons.contains("document-conversion-failed")
        {
            return LayabrushConvertExitStatus.outputFailure
        }
        if reasons.contains("input-io-failed") {
            return LayabrushConvertExitStatus.inputOutputFailure
        }
        return LayabrushConvertExitStatus.invalidInput
    }

    private static func resultCounts(
        _ results: [LayabrushConvertInputResult],
        command: Invocation.Command
    ) -> (succeeded: Int, failed: Int) {
        guard command == .convert || command == .batch else {
            let failed = results.count(where: { $0.status == "failed" })
            return (results.count - failed, failed)
        }
        var succeeded = 0
        var failed = 0
        for result in results {
            if result.documents.isEmpty {
                if result.status == "failed" {
                    failed += 1
                } else {
                    succeeded += 1
                }
                continue
            }
            succeeded += result.documents.count(where: {
                $0.status != "failed"
            })
            failed += result.documents.count(where: {
                $0.status == "failed"
            })
        }
        return (succeeded, failed)
    }

    private static func output(
        status: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) -> LayabrushConvertCommandOutput {
        LayabrushConvertCommandOutput(
            exitStatus: status,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private static func jsonOutput(
        _ value: some Encodable,
        status: Int32,
        standardError: String = ""
    ) throws -> LayabrushConvertCommandOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ConversionWriteError.jsonEncoding
        }
        return output(
            status: status,
            standardOutput: string + "\n",
            standardError: standardError
        )
    }

    private static func diagnosticFailure(
        stage: SyntheticV1DiagnosticStage
    ) -> LayabrushConvertCommandOutput {
        output(
            status: LayabrushConvertExitStatus.internalFailure,
            standardError:
            "layabrush-convert: synthetic-v1 diagnostic failed at "
                + "\(stage.rawValue)\n"
        )
    }
}

private struct Invocation {
    enum Command: String {
        case probe
        case inspect
        case convert
        case batch
    }

    let command: Command
    let json: Bool
    let replace: Bool
    let outputDirectory: URL
    let inputs: [String]

    init?(arguments: [String]) {
        guard let commandText = arguments.first,
              let command = Command(rawValue: commandText)
        else {
            return nil
        }
        var json = false
        var replace = false
        var outputDirectory: URL?
        var inputs = [String]()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                guard !json else { return nil }
                json = true
            case "--replace":
                guard !replace else { return nil }
                replace = true
            case "--output":
                guard outputDirectory == nil,
                      arguments.indices.contains(index + 1),
                      !arguments[index + 1].hasPrefix("--")
                else {
                    return nil
                }
                index += 1
                outputDirectory = URL(
                    fileURLWithPath: arguments[index],
                    isDirectory: true
                ).standardizedFileURL
            default:
                guard !argument.hasPrefix("--") else { return nil }
                inputs.append(argument)
            }
            index += 1
        }
        guard !inputs.isEmpty else { return nil }
        switch command {
        case .probe, .inspect:
            guard !replace, outputDirectory == nil else { return nil }
        case .convert:
            guard inputs.count == 1 else { return nil }
        case .batch:
            break
        }
        self.command = command
        self.json = json
        self.replace = replace
        self.outputDirectory = outputDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.inputs = inputs
    }
}

private enum ParserSelection {
    case synthetic
    case procreate

    var identifier: String {
        switch self {
        case .synthetic:
            SyntheticV1BrushParser.parserIdentifier
        case .procreate:
            ProcreateBrushParser.parserIdentifier
        }
    }

    func parse(_ source: Data) throws -> [ForeignBrushDocument] {
        switch self {
        case .synthetic:
            try SyntheticV1BrushParser().parse(source)
        case .procreate:
            try ProcreateBrushParser().parse(source)
        }
    }

    func map(
        _ document: ForeignBrushDocument
    ) throws -> ForeignBrushMappingResult {
        switch self {
        case .synthetic:
            try SyntheticV1BrushMapper().map(document)
        case .procreate:
            throw ParserSelectionError.noVerifiedMapper
        }
    }
}

private enum ParserSelectionError: Error {
    case noVerifiedMapper
}

private enum InputReadError: Error {
    case missing
    case tooLarge
    case io

    var reasonCode: String {
        switch self {
        case .missing:
            "input-missing"
        case .tooLarge:
            "input-too-large"
        case .io:
            "input-io-failed"
        }
    }
}

private enum ConversionWriteError: Error {
    case reopenMismatch
    case jsonEncoding
}
