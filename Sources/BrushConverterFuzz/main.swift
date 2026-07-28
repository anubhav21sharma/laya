import BrushConverterFuzzSupport
import Darwin
import Foundation

private struct FuzzCampaignReport: Codable {
    let schemaVersion: UInt16
    let commit: String
    let toolchain: String
    let durationSeconds: Double
    let crashArtifactPath: String
    let crashArtifactPresent: Bool
    let summary: BrushConverterFuzzSummary
}

@main
enum BrushConverterFuzzCommand {
    static func main() {
        do {
            let invocation = try Invocation.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: invocation.artifactDirectory,
                withIntermediateDirectories: true
            )
            let crashArtifact = invocation.artifactDirectory
                .appendingPathComponent("current-case.json")
            if fileManager.fileExists(atPath: crashArtifact.path) {
                try fileManager.removeItem(at: crashArtifact)
            }

            let harness = try BrushConverterFuzzHarness()
            let clock = ContinuousClock()
            let start = clock.now
            let summary = try harness.run(
                seed: invocation.seed,
                iterations: invocation.iterations
            ) { event in
                switch event {
                case let .willEvaluate(fuzzCase):
                    try BrushConverterFuzzReplayArtifact(
                        fuzzCase: fuzzCase
                    ).encoded().write(to: crashArtifact, options: .atomic)
                case .didEvaluate:
                    try fileManager.removeItem(at: crashArtifact)
                }
            }
            let elapsed = start.duration(to: clock.now)
            let components = elapsed.components
            let duration = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let report = FuzzCampaignReport(
                schemaVersion: 1,
                commit: invocation.commit,
                toolchain: invocation.toolchain,
                durationSeconds: duration,
                crashArtifactPath: crashArtifact.path,
                crashArtifactPresent:
                    fileManager.fileExists(atPath: crashArtifact.path),
                summary: summary
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            try fileManager.createDirectory(
                at: invocation.output
                    .deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(report).write(
                to: invocation.output,
                options: .atomic
            )
            print(
                "BRUSH CONVERTER FUZZ PASS "
                    + "seed=\(invocation.seed) "
                    + "iterations=\(summary.iterations) "
                    + "report=\(invocation.output.path)"
            )
        } catch {
            fputs(
                "BRUSH CONVERTER FUZZ ERROR: "
                    + "\(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }
    }
}

private struct Invocation {
    let seed: UInt64
    let iterations: Int
    let output: URL
    let artifactDirectory: URL
    let commit: String
    let toolchain: String

    static func parse(_ arguments: [String]) throws -> Self {
        var values = [String: String]()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--"),
                  index + 1 < arguments.count,
                  values[option] == nil
            else {
                throw InvocationError.invalidArguments
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        let expected = Set([
            "--seed",
            "--iterations",
            "--output",
            "--artifacts",
            "--commit",
            "--toolchain",
        ])
        guard Set(values.keys) == expected,
              let seedText = values["--seed"],
              let seed = parseSeed(seedText),
              let iterationsText = values["--iterations"],
              let iterations = Int(iterationsText),
              iterations > 0,
              iterations <= BrushConverterFuzzHarness.maximumIterations,
              let output = values["--output"],
              !output.isEmpty,
              let artifacts = values["--artifacts"],
              !artifacts.isEmpty,
              let commit = values["--commit"],
              isCommit(commit),
              let toolchain = values["--toolchain"],
              !toolchain.isEmpty,
              toolchain.utf8.count <= 1_024
        else {
            throw InvocationError.invalidArguments
        }
        return Self(
            seed: seed,
            iterations: iterations,
            output: URL(fileURLWithPath: output),
            artifactDirectory: URL(fileURLWithPath: artifacts),
            commit: commit,
            toolchain: toolchain
        )
    }

    private static func parseSeed(_ value: String) -> UInt64? {
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }

    private static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.unicodeScalars.allSatisfy {
                ("0" ... "9").contains(Character($0))
                    || ("a" ... "f").contains(Character($0))
            }
    }
}

private enum InvocationError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        "usage: brush-converter-fuzz "
            + "--seed UINT64 --iterations COUNT --output REPORT.json "
            + "--artifacts DIRECTORY --commit FULL_SHA "
            + "--toolchain DESCRIPTION"
    }
}
