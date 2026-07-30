import BrushDepositionEvidenceValidation
import Darwin
import Foundation

@main
enum BrushDepositionEvidenceGate {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try parse(arguments)
            let status = try StageFourEvidenceValidator.validate(
                artifactRoot: URL(fileURLWithPath: options.artifacts),
                expectedCommit: options.commit,
                expectedSourceTreeSHA256: options.sourceTreeSHA256
            )
            switch status {
            case .passed:
                print("BRUSH DEPOSITION EVIDENCE PASS")
                exit(0)
            case let .performancePending(gpuName):
                print(
                    "BRUSH DEPOSITION EVIDENCE PERFORMANCE PENDING gpu=\(gpuName)"
                )
                exit(2)
            }
        } catch {
            fputs(
                "BRUSH DEPOSITION EVIDENCE FAIL: \(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }
    }

    private struct Options {
        let artifacts: String
        let commit: String
        let sourceTreeSHA256: String
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        guard arguments.count == 6 else {
            throw StageFourEvidenceValidationError.invalid(usage)
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard [
                "--artifacts", "--commit", "--source-tree-sha256",
            ].contains(flag),
                values[flag] == nil
            else {
                throw StageFourEvidenceValidationError.invalid(usage)
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let artifacts = values["--artifacts"],
              artifacts.hasPrefix("/"),
              let commit = values["--commit"],
              let sourceTreeSHA256 = values["--source-tree-sha256"]
        else {
            throw StageFourEvidenceValidationError.invalid(usage)
        }
        return Options(
            artifacts: artifacts,
            commit: commit,
            sourceTreeSHA256: sourceTreeSHA256
        )
    }

    private static let usage =
        "usage: BrushDepositionEvidenceGate --artifacts <absolute-path> "
            + "--commit <40-char-sha> --source-tree-sha256 <64-char-sha>"
}
