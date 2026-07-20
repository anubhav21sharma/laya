import CShaderTypes
import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Test
func reflectedFragmentPacksEveryAffineAndActiveClipScalar() {
    let fragment = CellFragment(
        cell: CellIndex(column: -3, row: 7),
        imageOrdinal: 1,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(-10, 0),
            yAxis: SIMD2(0, 10),
            translation: SIMD2(251, 19)
        ),
        brushClip: ConvexClip(
            halfPlanes: [
                HalfPlane2D(normal: SIMD2(1, 0), offset: -0.25),
                HalfPlane2D(normal: SIMD2(0, -1), offset: -0.75),
            ]
        )
    )

    let instance = PatternProjectedStampInstance(
        fragment: fragment,
        radius: 10
    )

    #expect(instance.canonicalXAxis == SIMD2<Float>(-10, 0))
    #expect(instance.canonicalYAxis == SIMD2<Float>(0, 10))
    #expect(instance.canonicalTranslation == SIMD2<Float>(251, 19))
    #expect(instance.radius == 10)
    #expect(instance.clipCount == 2)
    #expect(instance.clip0.normal == SIMD2<Float>(1, 0))
    #expect(instance.clip0.offset == -0.25)
    #expect(instance.clip0.padding == 0)
    #expect(instance.clip1.normal == SIMD2<Float>(0, -1))
    #expect(instance.clip1.offset == -0.75)
    #expect(instance.clip1.padding == 0)
}

@Test
func inactiveClipSlotsAreDeterministicallyZeroFilled() {
    let instance = PatternProjectedStampInstance(
        fragment: reflectedTwoPlaneFragment(),
        radius: 10
    )

    #expect(instance.clip2.normal == .zero)
    #expect(instance.clip2.offset == 0)
    #expect(instance.clip2.padding == 0)
    #expect(instance.clip3.normal == .zero)
    #expect(instance.clip3.offset == 0)
    #expect(instance.clip3.padding == 0)
}

@Test
func packingAcceptsExactAbsoluteRadiusBounds() {
    let fragment = reflectedTwoPlaneFragment()

    #expect(
        PatternProjectedStampInstance(fragment: fragment, radius: 1).radius
            == 1
    )
    #expect(
        PatternProjectedStampInstance(fragment: fragment, radius: 1_000)
            .radius == 1_000
    )
}

@Test
func packingRejectsRadiusOutsideTheAbsoluteClamp() throws {
    if let radiusText = ProcessInfo.processInfo.environment[
        "PATTERN_PROJECTED_STAMP_INVALID_RADIUS"
    ] {
        _ = PatternProjectedStampInstance(
            fragment: reflectedTwoPlaneFragment(),
            radius: Float(radiusText)!
        )
        return
    }

    for radius in [Float(1).nextDown, Float(1_000).nextUp] {
        let result = try runRadiusValidationSubprocess(radius: radius)
        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "Precondition failed: Projected stamp radius must be finite and within 1...1000"
            )
        )
    }
}

private func reflectedTwoPlaneFragment() -> CellFragment {
    CellFragment(
        cell: CellIndex(column: 0, row: 0),
        imageOrdinal: 0,
        canonicalFromBrush: Affine2D(
            xAxis: SIMD2(-10, 0),
            yAxis: SIMD2(0, 10),
            translation: SIMD2(20, 30)
        ),
        brushClip: ConvexClip(
            halfPlanes: [
                HalfPlane2D(normal: SIMD2(1, 0), offset: -0.5),
                HalfPlane2D(normal: SIMD2(0, 1), offset: -0.5),
            ]
        )
    )
}

private func runRadiusValidationSubprocess(
    radius: Float
) throws -> (status: Int32, standardError: String) {
    let testExecutablePath = projectedStampTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "packingRejectsRadiusOutsideTheAbsoluteClamp",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_PROJECTED_STAMP_INVALID_RADIUS": String(radius)],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    return (process.terminationStatus, errorOutput)
}

private func projectedStampTestExecutablePath() -> String {
    guard
        let optionIndex = CommandLine.arguments.firstIndex(
            of: "--test-bundle-path"
        ),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    return CommandLine.arguments[optionIndex + 1]
}
