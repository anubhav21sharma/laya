import Foundation
import Metal
import PatternEngine

public enum RadialHarnessScenario:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case generic
    case axis
    case center
    case reflected
    case largeFootprint
    case erase
    case lock
    case export
}

public enum RadialHarnessSceneError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedSchema(Int)
    case invalidName
    case invalidGeometry
    case invalidExpectedMismatchCount(Int)
    case measurementMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(schema):
            "Unsupported radial harness schema \(schema)."
        case .invalidName:
            "Radial harness scene name must not be empty."
        case .invalidGeometry:
            "Radial harness scene geometry is invalid."
        case let .invalidExpectedMismatchCount(count):
            "Expected mismatch count \(count) must be nonnegative."
        case let .measurementMismatch(expected, actual):
            "Radial harness expected \(expected) mismatches, measured \(actual)."
        }
    }
}

public struct RadialHarnessScene: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schema: Int
    public let name: String
    public let scenario: RadialHarnessScenario
    public let kind: RadialSymmetryKind
    public let rayCount: Int
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let centerX: Float
    public let centerY: Float
    public let referenceAngleRadians: Float
    public let probeX: Float
    public let probeY: Float
    public let diameter: Float
    public let expectedMismatchCount: Int

    public init(
        schema: Int = currentSchema,
        name: String,
        scenario: RadialHarnessScenario,
        kind: RadialSymmetryKind,
        rayCount: Int,
        canvasWidth: Int,
        canvasHeight: Int,
        centerX: Float,
        centerY: Float,
        referenceAngleRadians: Float,
        probeX: Float,
        probeY: Float,
        diameter: Float,
        expectedMismatchCount: Int
    ) {
        self.schema = schema
        self.name = name
        self.scenario = scenario
        self.kind = kind
        self.rayCount = rayCount
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.centerX = centerX
        self.centerY = centerY
        self.referenceAngleRadians = referenceAngleRadians
        self.probeX = probeX
        self.probeY = probeY
        self.diameter = diameter
        self.expectedMismatchCount = expectedMismatchCount
    }

    public static func decode(_ data: Data) throws -> Self {
        let scene = try JSONDecoder().decode(Self.self, from: data)
        try scene.validate()
        return scene
    }

    public var canvasSize: PixelSize {
        PixelSize(width: canvasWidth, height: canvasHeight)
    }

    public var configuration: RadialSymmetryConfiguration {
        RadialSymmetryConfiguration(
            kind: kind,
            rayCount: rayCount,
            center: WorldPoint(x: centerX, y: centerY),
            referenceAngleRadians: referenceAngleRadians
        )
    }

    public var probe: WorldPoint {
        WorldPoint(x: probeX, y: probeY)
    }

    public func validate(
        _ measurement: RadialHarnessMeasurement
    ) throws {
        guard measurement.mismatchCount == expectedMismatchCount else {
            throw RadialHarnessSceneError.measurementMismatch(
                expected: expectedMismatchCount,
                actual: measurement.mismatchCount
            )
        }
    }

    private func validate() throws {
        guard schema == Self.currentSchema else {
            throw RadialHarnessSceneError.unsupportedSchema(schema)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RadialHarnessSceneError.invalidName
        }
        guard expectedMismatchCount >= 0 else {
            throw RadialHarnessSceneError.invalidExpectedMismatchCount(
                expectedMismatchCount
            )
        }
        guard diameter.isFinite, (1...2_000).contains(diameter),
              probeX.isFinite, probeY.isFinite
        else {
            throw RadialHarnessSceneError.invalidGeometry
        }
        do {
            _ = try SymmetryDescriptorCompiler.compile(
                finiteConfiguration: .radial(configuration),
                canvasSize: canvasSize
            )
        } catch {
            throw RadialHarnessSceneError.invalidGeometry
        }
    }
}

public struct RadialHarnessMeasurement: Codable, Equatable, Sendable {
    public let sceneName: String
    public let mismatchCount: Int
    public let oracleFoldMismatchCount: Int
    public let metalMissingOrbitCount: Int
    public let eraseResidualCount: Int
    public let lockViolationCount: Int
    public let exportMismatchCount: Int
    public let projectedFragmentCount: Int
    public let atlasResidentBytesPerSurface: Int
    public let projectionMilliseconds: Double
    public let commitCPUMilliseconds: Double
    public let commitGPUMilliseconds: Double
    public let exportMilliseconds: Double
    public let exportHash: UInt64
}

@MainActor
public enum RadialHarnessRunner {
    public static func run(
        _ scene: RadialHarnessScene,
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws -> RadialHarnessMeasurement {
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(scene.configuration),
            canvasSize: scene.canvasSize
        )
        let orbit = RadialCoverageOracle.orbit(
            of: scene.probe,
            configuration: scene.configuration
        ).filter {
            $0.x >= 0 && $0.y >= 0
                && $0.x < Float(scene.canvasWidth)
                && $0.y < Float(scene.canvasHeight)
        }
        let expectedFold = radialHarnessAtlasPoint(
            RadialCoverageOracle.fold(
                scene.probe,
                configuration: .radial(scene.configuration),
                canvasSize: scene.canvasSize
            ),
            strategy: strategy
        )
        let oracleFoldMismatchCount = orbit.reduce(into: 0) {
            mismatches,
            point in
            let production = strategy.displayFold(point)
            let oracle = radialHarnessAtlasPoint(
                RadialCoverageOracle.fold(
                    point,
                    configuration: .radial(scene.configuration),
                    canvasSize: scene.canvasSize
                ),
                strategy: strategy
            )
            if !radialHarnessPointsEqual(production, oracle)
                || !radialHarnessPointsEqual(production, expectedFold)
            {
                mismatches += 1
            }
        }

        let radius = scene.diameter * 0.5
        let projectionStart = CFAbsoluteTimeGetCurrent()
        let fragments = TilingProjection.fragments(
            for: StampFootprint(
                brushToWorld: Affine2D(
                    xAxis: SIMD2(radius, 0),
                    yAxis: SIMD2(0, radius),
                    translation: scene.probe.simd
                ),
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-1, -1),
                    maximum: SIMD2(1, 1)
                ),
                coverageSymmetry: .rotationAndReflectionInvariant
            ),
            using: strategy
        )
        let projectionMilliseconds =
            (CFAbsoluteTimeGetCurrent() - projectionStart) * 1_000

        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(scene.canvasWidth),
                height: Float(scene.canvasHeight)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: scene.canvasSize,
                finiteConfiguration: .radial(scene.configuration)
            )
        )
        let commitMetrics = try commit(
            renderer,
            at: scene.probe,
            diameter: scene.diameter,
            token: 1,
            mode: .draw
        )
        let display = try renderer.renderOffscreenDisplayForHarness(
            width: scene.canvasWidth,
            height: scene.canvasHeight,
            showGridLines: false
        )
        let displayBytes = radialHarnessTextureBytes(display.texture)
        let metalMissingOrbitCount = orbit.filter {
            !radialHarnessPixelHasInk(
                displayBytes,
                width: scene.canvasWidth,
                height: scene.canvasHeight,
                point: $0
            )
        }.count

        var eraseResidualCount = 0
        if scene.scenario == .erase {
            _ = try commit(
                renderer,
                at: scene.probe,
                diameter: max(scene.diameter + 8, scene.diameter * 1.5),
                token: 2,
                mode: .erase
            )
            let erased = try renderer.exportFiniteCanvas(
                transparentBackground: true
            )
            eraseResidualCount = orbit.filter {
                radialHarnessPixelHasInk(
                    erased.bgra8Bytes,
                    width: scene.canvasWidth,
                    height: scene.canvasHeight,
                    point: $0
                )
            }.count
        }

        var lockViolationCount = 0
        if scene.scenario == .lock {
            let changed = RadialSymmetryConfiguration(
                kind: scene.kind == .rotation ? .mandala : .rotation,
                rayCount: max(2, min(32, scene.rayCount)),
                center: scene.configuration.center,
                referenceAngleRadians:
                    scene.referenceAngleRadians + Float.pi / 13
            )
            do {
                try renderer.applyFiniteConfiguration(.radial(changed))
                lockViolationCount = 1
            } catch MetalRendererError.radialGeometryLocked {
                lockViolationCount = renderer.radialGeometryLocked ? 0 : 1
            } catch {
                lockViolationCount = 1
            }
        }

        let exportStart = CFAbsoluteTimeGetCurrent()
        let baselineExport = try renderer.exportFiniteCanvas(
            transparentBackground: true
        )
        let exportMilliseconds =
            (CFAbsoluteTimeGetCurrent() - exportStart) * 1_000
        var exportMismatchCount = 0
        if scene.scenario == .export {
            let beforeConfiguration = renderer.documentConfiguration
            let beforeLock = renderer.radialGeometryLocked
            renderer.pan(byScreenDelta: SIMD2(17, -11))
            renderer.zoom(
                by: 1.75,
                anchor: ScreenPoint(x: 9, y: 13)
            )
            renderer.setInteractiveGridVisibility(true)
            let transformed = try renderer.exportFiniteCanvas(
                transparentBackground: true
            )
            if transformed != baselineExport {
                exportMismatchCount += 1
            }
            if renderer.documentConfiguration != beforeConfiguration
                || renderer.radialGeometryLocked != beforeLock
            {
                exportMismatchCount += 1
            }
        }

        let mismatchCount = oracleFoldMismatchCount
            + metalMissingOrbitCount
            + eraseResidualCount
            + lockViolationCount
            + exportMismatchCount
            + (fragments.isEmpty ? 1 : 0)
        let residentBytes = strategy.compiledSymmetry.domain.finite?
            .radial.layout?.residentBytesPerSurface ?? 0
        return RadialHarnessMeasurement(
            sceneName: scene.name,
            mismatchCount: mismatchCount,
            oracleFoldMismatchCount: oracleFoldMismatchCount,
            metalMissingOrbitCount: metalMissingOrbitCount,
            eraseResidualCount: eraseResidualCount,
            lockViolationCount: lockViolationCount,
            exportMismatchCount: exportMismatchCount,
            projectedFragmentCount: fragments.count,
            atlasResidentBytesPerSurface: residentBytes,
            projectionMilliseconds: projectionMilliseconds,
            commitCPUMilliseconds: commitMetrics.cpuEncodeMilliseconds,
            commitGPUMilliseconds: commitMetrics.gpuMilliseconds,
            exportMilliseconds: exportMilliseconds,
            exportHash: radialHarnessHash(baselineExport.bgra8Bytes)
        )
    }

    private static func commit(
        _ renderer: GridRenderer,
        at point: WorldPoint,
        diameter: Float,
        token rawToken: UInt64,
        mode: StrokeCompositeMode
    ) throws -> GPUFrameMetrics {
        let token = RendererOperationToken(rawValue: rawToken)
        let style = StrokeRenderStyle(
            color: .black,
            diameter: diameter,
            compositeMode: mode,
            eraserStrength: 1
        )
        try renderer.beginStroke(
            token: token,
            sample: .mouse(
                position: ScreenPoint(x: point.x, y: point.y),
                timestamp: 0,
                phase: .began
            ),
            style: style
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: .mouse(
                position: ScreenPoint(x: point.x, y: point.y),
                timestamp: 0,
                phase: .ended
            ),
            maximumRetainedBytes: 16 * 1_024 * 1_024
        )
        _ = try renderer.flushPendingLiveForHarness()
        return try renderer.finishCommitForHarness()
    }
}

private func radialHarnessPointsEqual(
    _ lhs: CanonicalPoint?,
    _ rhs: CanonicalPoint?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (lhs?, rhs?):
        hypot(lhs.x - rhs.x, lhs.y - rhs.y) < 0.001
    default:
        false
    }
}

private func radialHarnessAtlasPoint(
    _ logical: CanonicalPoint?,
    strategy: TilingStrategy
) -> CanonicalPoint? {
    guard let logical else { return nil }
    guard let layout = strategy.compiledSymmetry.domain.finite?
        .radial.layout
    else {
        return logical
    }
    guard let atlas = layout.atlasPoint(
        forLogical: SIMD2(logical.x, logical.y)
    ) else {
        return nil
    }
    return CanonicalPoint(x: atlas.x, y: atlas.y)
}

private func radialHarnessTextureBytes(
    _ texture: any MTLTexture
) -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * texture.height
    )
    bytes.withUnsafeMutableBytes { storage in
        texture.getBytes(
            storage.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    return bytes
}

private func radialHarnessPixelHasInk(
    _ bytes: [UInt8],
    width: Int,
    height: Int,
    point: WorldPoint
) -> Bool {
    let centerX = Int(point.x.rounded())
    let centerY = Int(point.y.rounded())
    guard centerX >= 0, centerY >= 0,
          centerX < width, centerY < height
    else {
        return false
    }
    for y in max(0, centerY - 2)...min(height - 1, centerY + 2) {
        for x in max(0, centerX - 2)...min(width - 1, centerX + 2) {
            let offset = (y * width + x) * 4
            if bytes[offset + 3] > 32,
               bytes[offset] < 160,
               bytes[offset + 1] < 160,
               bytes[offset + 2] < 160
            {
                return true
            }
        }
    }
    return false
}

private func radialHarnessHash(_ bytes: [UInt8]) -> UInt64 {
    bytes.reduce(1_469_598_103_934_665_603) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
}

private extension WorldPoint {
    var simd: SIMD2<Float> { SIMD2(x, y) }
}
