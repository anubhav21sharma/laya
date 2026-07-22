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
        radius: 10,
        color: InkColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)!
    )

    #expect(instance.canonicalXAxis == SIMD2<Float>(-10, 0))
    #expect(instance.canonicalYAxis == SIMD2<Float>(0, 10))
    #expect(instance.canonicalTranslation == SIMD2<Float>(251, 19))
    #expect(instance.radius == 10)
    #expect(instance.color == SIMD4<Float>(0.2, 0.4, 0.6, 0.8))
    #expect(instance.clipCount == 2)
    #expect(instance.clip0.normal == SIMD2<Float>(1, 0))
    #expect(instance.clip0.offset == -0.25)
    #expect(instance.clip0.padding == 0)
    #expect(instance.clip1.normal == SIMD2<Float>(0, -1))
    #expect(instance.clip1.offset == -0.75)
    #expect(instance.clip1.padding == 0)
    #expect(instance.brushAttributes == SIMD4<Float>(1, 1, 0, 0))
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
func legacyGridSeamTracePacksExactProjectedInstancesAndDirtyRegions() {
    let sample = StrokeTraceFixtures.gridSeam.samples[0]
    let radius: Float = 10
    let footprint = StampFootprint(
        brushToWorld: Affine2D(
            xAxis: SIMD2(radius, 0),
            yAxis: SIMD2(0, radius),
            translation: sample.position.simd
        ),
        localBounds: AxisAlignedRect(
            minimum: SIMD2(-1, -1),
            maximum: SIMD2(1, 1)
        ),
        coverageSymmetry: .halfTurnInvariant
    )
    let fragments = TilingProjection.fragments(
        for: footprint,
        using: TilingStrategy(
            kind: .grid,
            tileSize: PatternSize(width: 256, height: 256)
        )
    )
    let color = InkColor(
        red: 0.2,
        green: 0.4,
        blue: 0.6,
        alpha: 0.8
    )!
    let instances = fragments.map {
        PatternProjectedStampInstance(
            fragment: $0,
            radius: radius,
            color: color
        )
    }

    #expect(fragments.map(\.cell) == [
        CellIndex(column: 0, row: 0),
        CellIndex(column: 1, row: 0),
    ])
    #expect(fragments.map(\.imageOrdinal) == [0, 0])
    #expect(fragments.map(\.canonicalFromBrush.translation) == [
        SIMD2<Float>(250, 128),
        SIMD2<Float>(-6, 128),
    ])
    #expect(instances.map(\.canonicalXAxis) == [
        SIMD2<Float>(10, 0),
        SIMD2<Float>(10, 0),
    ])
    #expect(instances.map(\.canonicalYAxis) == [
        SIMD2<Float>(0, 10),
        SIMD2<Float>(0, 10),
    ])
    #expect(instances.map(\.radius) == [10, 10])
    #expect(instances.map(\.color) == [color.simd, color.simd])
    #expect(instances.map(\.clipCount) == [4, 4])
    #expect(instances[0].clip0.normal == SIMD2<Float>(1, 0))
    #expect(instances[0].clip0.offset == -25)
    #expect(instances[0].clip1.normal == SIMD2<Float>(-1, 0))
    #expect(abs(instances[0].clip1.offset - -0.6) < 0.0001)
    #expect(instances[1].clip0.normal == SIMD2<Float>(1, 0))
    #expect(abs(instances[1].clip0.offset - 0.6) < 0.0001)
    #expect(instances[1].clip1.normal == SIMD2<Float>(-1, 0))
    #expect(abs(instances[1].clip1.offset - -26.2) < 0.0001)
    for instance in instances {
        #expect(instance.clip2.normal == SIMD2<Float>(0, 1))
        #expect(abs(instance.clip2.offset - -12.8) < 0.0001)
        #expect(instance.clip3.normal == SIMD2<Float>(0, -1))
        #expect(abs(instance.clip3.offset - -12.8) < 0.0001)
    }
    #expect(
        fragments.map {
            TilingProjection.dirtyPixelRect(for: $0, radius: radius)
        } == [
            PixelRect(minX: 239, minY: 117, maxX: 261, maxY: 139)!,
            PixelRect(minX: -17, minY: 117, maxX: 5, maxY: 139)!,
        ]
    )
    #expect(MemoryLayout<PatternProjectedStampInstance>.stride == 128)
}

@Test
func packingAcceptsExactAbsoluteRadiusBounds() {
    let fragment = reflectedTwoPlaneFragment()

    #expect(
        PatternProjectedStampInstance(fragment: fragment, radius: 0.25).radius
            == 0.25
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

    for radius in [Float.zero, Float(1_000).nextUp] {
        let result = try runRadiusValidationSubprocess(radius: radius)
        #expect(result.status != 0)
        #expect(
            result.standardError.contains(
                "Precondition failed: Projected stamp radius must be finite and within (0, 1000]"
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
