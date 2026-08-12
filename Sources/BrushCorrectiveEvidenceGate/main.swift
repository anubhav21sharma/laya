import Darwin
import Foundation
import MetalRendererDiagnostics

@main
enum BrushCorrectiveEvidenceGateCommand {
    static func main() {
        do {
            let options = try Options(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            let result = try BrushCorrectiveGate.validateArtifacts(
                artifactRoot: options.artifactRoot,
                expectedCommit: options.commit,
                expectedSourceTreeSHA256: options.sourceTreeSHA256
            )
            if result.manualAndPhysicalPending {
                print("BRUSH CORRECTIVE AUTOMATED PASS; MANUAL/PHYSICAL PENDING")
                exit(2)
            }
            print("BRUSH CORRECTIVE EVIDENCE PASS")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(
                "BRUSH CORRECTIVE EVIDENCE FAIL: \(error.localizedDescription)\n"
                    .utf8
            ))
            exit(1)
        }
    }

    private struct Options {
        let artifactRoot: URL
        let commit: String
        let sourceTreeSHA256: String

        init(arguments: [String]) throws {
            guard arguments.count == 6 else { throw UsageError.invalid }
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard [
                    "--artifacts", "--commit", "--source-tree-sha256",
                ].contains(flag), values[flag] == nil else {
                    throw UsageError.invalid
                }
                values[flag] = arguments[index + 1]
                index += 2
            }
            guard let artifacts = values["--artifacts"],
                  artifacts.hasPrefix("/"),
                  let commit = values["--commit"],
                  let sourceTreeSHA256 = values["--source-tree-sha256"]
            else {
                throw UsageError.invalid
            }
            artifactRoot = URL(fileURLWithPath: artifacts)
                .standardizedFileURL
            self.commit = commit
            self.sourceTreeSHA256 = sourceTreeSHA256
        }
    }

    private enum UsageError: Error, LocalizedError {
        case invalid

        var errorDescription: String? {
            "usage: BrushCorrectiveEvidenceGate --artifacts <absolute-path> "
                + "--commit <40-char-sha> --source-tree-sha256 <64-char-sha>"
        }
    }
}
