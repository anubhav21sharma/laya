import Foundation
import PatternEngine
import simd
import Testing

@Test
func axisAlignedRectUsesHalfOpenIntersection() {
    let unit = AxisAlignedRect(
        minimum: SIMD2<Float>(0, 0),
        maximum: SIMD2<Float>(1, 1)
    )
    #expect(unit.intersects(
        AxisAlignedRect(
            minimum: SIMD2<Float>(0.5, 0.5),
            maximum: SIMD2<Float>(2, 2)
        )
    ))
    #expect(!unit.intersects(
        AxisAlignedRect(
            minimum: SIMD2<Float>(1, 0),
            maximum: SIMD2<Float>(2, 1)
        )
    ))
}

@Test
func transformedRectEnclosesAllTransformedCorners() {
    let rectangle = AxisAlignedRect(
        minimum: SIMD2<Float>(-1, -2),
        maximum: SIMD2<Float>(2, 3)
    )
    let affine = Affine2D(
        xAxis: SIMD2(0, 1),
        yAxis: SIMD2(-1, 0),
        translation: SIMD2(10, 20)
    )

    #expect(rectangle.corners == [
        SIMD2<Float>(-1, -2),
        SIMD2<Float>(2, -2),
        SIMD2<Float>(2, 3),
        SIMD2<Float>(-1, 3),
    ])
    #expect(rectangle.transformed(by: affine) == AxisAlignedRect(
        minimum: SIMD2<Float>(7, 19),
        maximum: SIMD2<Float>(12, 22)
    ))
}

@Test
func convexClipContainsOnlyPointsInsideEveryPlane() {
    let clip = ConvexClip(halfPlanes: [
        HalfPlane2D(normal: SIMD2(1, 0), offset: 0),
        HalfPlane2D(normal: SIMD2(-1, 0), offset: -1),
        HalfPlane2D(normal: SIMD2(0, 1), offset: 0),
        HalfPlane2D(normal: SIMD2(0, -1), offset: -1),
    ])
    #expect(clip.contains(SIMD2<Float>(0.5, 0.5), tolerance: 0))
    #expect(!clip.contains(SIMD2<Float>(1.01, 0.5), tolerance: 0))
}

@Test
func halfPlaneAcceptsPointsWithinTolerance() {
    let plane = HalfPlane2D(normal: SIMD2(1, 0), offset: 0)

    #expect(plane.contains(SIMD2<Float>(-0.0001, 0), tolerance: 0.0001))
    #expect(!plane.contains(SIMD2<Float>(-0.0002, 0), tolerance: 0.0001))
}

@Test
func invalidConstructionTrapsInSubprocess() throws {
    if let invalidCase = ProcessInfo.processInfo.environment["PATTERN_ENGINE_INVALID_GEOMETRY"] {
        triggerInvalidConstruction(named: invalidCase)
    }

    for invalidCase in [
        "fifthPlane",
        "zeroNormal",
        "nonNormalizedNormal",
        "singularAffineInverse",
        "nonFiniteBounds",
    ] {
        try expectSubprocessTrap(for: invalidCase)
    }
}

private func expectSubprocessTrap(for invalidCase: String) throws {
    let testExecutablePath = swiftTestingTestExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "invalidConstructionTrapsInSubprocess",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_ENGINE_INVALID_GEOMETRY": invalidCase],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus != 0)
}

private func swiftTestingTestExecutablePath() -> String {
    guard
        let optionIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    return CommandLine.arguments[optionIndex + 1]
}

private func triggerInvalidConstruction(named invalidCase: String) -> Never {
    switch invalidCase {
    case "fifthPlane":
        _ = ConvexClip(halfPlanes: Array(
            repeating: HalfPlane2D(normal: SIMD2(1, 0), offset: 0),
            count: 5
        ))
    case "zeroNormal":
        _ = HalfPlane2D(normal: SIMD2(0, 0), offset: 0)
    case "nonNormalizedNormal":
        _ = HalfPlane2D(normal: SIMD2(2, 0), offset: 0)
    case "singularAffineInverse":
        _ = Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(2, 0),
            translation: SIMD2(0, 0)
        ).inverted()
    case "nonFiniteBounds":
        _ = AxisAlignedRect(
            minimum: SIMD2(Float.nan, 0),
            maximum: SIMD2(1, 1)
        )
    default:
        fatalError("Unknown invalid geometry case: \(invalidCase)")
    }

    fatalError("Invalid geometry construction did not trap")
}
