import Darwin
import Foundation
import MetalRendererDiagnostics

@main
enum BrushFoundationEvidenceGate {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "record-compiler-counters" {
            guard arguments.count == 3 else {
                usage()
            }
            do {
                let evidence = try await BrushFoundationCompilerProbe.capture(
                    commit: arguments[2]
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [
                    .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
                ]
                let output = URL(fileURLWithPath: arguments[1])
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try encoder.encode(evidence).write(to: output, options: .atomic)
                print("BRUSH COMPILER COUNTERS RECORDED path=\(output.path)")
                return
            } catch {
                fail(error)
            }
        }

        guard arguments.count == 2 else {
            usage()
        }
        do {
            let status = try BrushFoundationEvidenceValidator.validate(
                artifactRoot: URL(fileURLWithPath: arguments[0]),
                expectedCommit: arguments[1]
            )
            switch status {
            case .passed:
                print("BRUSH FOUNDATION EVIDENCE PASS")
            }
        } catch {
            fail(error)
        }
    }

    private static func usage() -> Never {
        fputs(
            "usage: BrushFoundationEvidenceGate ARTIFACT_ROOT COMMIT\n"
                + "       BrushFoundationEvidenceGate record-compiler-counters OUTPUT COMMIT\n",
            stderr
        )
        exit(64)
    }

    private static func fail(_ error: Error) -> Never {
        fputs(
            "BRUSH FOUNDATION EVIDENCE ERROR: \(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
}
