import Darwin
import Foundation
import ProfessionalBrushEvidenceValidation

@main
enum ProfessionalBrushEvidenceGate {
    static func main() {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            let status = try ProfessionalBrushArtifactValidator.validate(
                artifactRoot: URL(fileURLWithPath: options.artifacts),
                expectedCommit: options.commit,
                expectedSourceTreeSHA256: options.sourceTreeSHA256
            )
            switch status {
            case .passed:
                print("PROFESSIONAL BRUSH EVIDENCE PASS")
                exit(0)
            case .pending:
                print(
                    "PROFESSIONAL BRUSH EVIDENCE MANUAL/PHYSICAL PENDING"
                )
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(
                Data(
                    "PROFESSIONAL BRUSH EVIDENCE FAIL: \(error.localizedDescription)\n"
                        .utf8
                )
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
            throw ProfessionalBrushArtifactValidationError.invalid(usage)
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
                throw ProfessionalBrushArtifactValidationError.invalid(
                    usage
                )
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let artifacts = values["--artifacts"],
              artifacts.hasPrefix("/"),
              let commit = values["--commit"],
              let sourceTreeSHA256 = values["--source-tree-sha256"]
        else {
            throw ProfessionalBrushArtifactValidationError.invalid(usage)
        }
        return Options(
            artifacts: artifacts,
            commit: commit,
            sourceTreeSHA256: sourceTreeSHA256
        )
    }

    private static let usage =
        "usage: ProfessionalBrushEvidenceGate --artifacts <absolute-path> "
        + "--commit <40-char-sha> --source-tree-sha256 <64-char-sha>"
}
