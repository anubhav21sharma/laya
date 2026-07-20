import Darwin
import Foundation
import MetalRenderer

guard CommandLine.arguments.count == 5 else {
    fputs(
        "usage: SliceThreeEvidenceGate SLICE2_ROOT SLICE3_ROOT SLICE1_ROOT COMMIT\n",
        stderr
    )
    exit(64)
}

do {
    let status = try SliceThreeEvidenceValidator.validate(
        sliceTwoRoot: URL(fileURLWithPath: CommandLine.arguments[1]),
        sliceThreeRoot: URL(fileURLWithPath: CommandLine.arguments[2]),
        sliceOneRoot: URL(fileURLWithPath: CommandLine.arguments[3]),
        expectedCommit: CommandLine.arguments[4]
    )
    switch status {
    case .passed:
        print("SLICE3 EVIDENCE PASS")
    case let .performancePending(gpuName):
        fputs(
            "SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment '\(gpuName)'.\n",
            stderr
        )
        exit(2)
    }
} catch {
    fputs("SLICE3 BENCHMARK ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
