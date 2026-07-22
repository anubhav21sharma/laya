import Darwin
import Foundation
import MetalRenderer

guard CommandLine.arguments.count == 5 else {
    fputs(
        "usage: SliceFourEvidenceGate POSITIVE_ROOT NEGATIVE_ROOT SCENE_ROOT COMMIT\n",
        stderr
    )
    exit(64)
}

do {
    let status = try SliceFourEvidenceValidator.validate(
        positiveRoot: URL(fileURLWithPath: CommandLine.arguments[1]),
        negativeRoot: URL(fileURLWithPath: CommandLine.arguments[2]),
        sceneRoot: URL(fileURLWithPath: CommandLine.arguments[3]),
        expectedCommit: CommandLine.arguments[4]
    )
    switch status {
    case .passed:
        print("SLICE4 EVIDENCE PASS")
    case let .performancePending(gpuName):
        fputs(
            "SLICE4 PERFORMANCE PENDING: unstable real-Metal timing environment '\(gpuName)'.\n",
            stderr
        )
        exit(2)
    }
} catch {
    fputs("SLICE4 EVIDENCE ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
