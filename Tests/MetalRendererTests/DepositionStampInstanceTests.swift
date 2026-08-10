import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Deposition stamp instance")
struct DepositionStampInstanceTests {
    @Test
    func packsProjectedTipCoverageIdentityAndFourClips() throws {
        let fragment = CellFragment(
            cell: CellIndex(column: 3, row: -2),
            imageOrdinal: 7,
            canonicalFromBrush: Affine2D(
                xAxis: SIMD2(0, -2),
                yAxis: SIMD2(-3, 0),
                translation: SIMD2(7, 11)
            ),
            brushClip: ConvexClip(halfPlanes: [
                HalfPlane2D(normal: SIMD2(1, 0), offset: -1),
                HalfPlane2D(normal: SIMD2(0, 1), offset: -2),
                HalfPlane2D(normal: SIMD2(-1, 0), offset: -3),
                HalfPlane2D(normal: SIMD2(0, -1), offset: -4),
            ]),
            operation: CompiledGroupOperation(
                rotationStep: 1,
                rotationOrder: 4,
                reflected: true
            )
        )
        let color = try #require(
            InkColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.5)
        )
        let dab = logicalDab(
            brushToWorld: .identity,
            radius: 5,
            flow: 0.7,
            strokeOpacity: 0.6,
            hardness: 0.8,
            color: color,
            materialContribution: 0.9,
            ordinal: 0xFEDC_BA98_7654_3210,
            isPredicted: true
        )

        let instance = try PatternDepositionStampInstance(
            fragment: fragment,
            dab: dab,
            logicalOrdinal: dab.ordinal,
            isometryOrdinal: 23
        )

        #expect(instance.tipFrame0 == SIMD4(0, -2, -3, 0))
        #expect(instance.tipFrame1 == SIMD4(7, 11, 5, 0))
        #expect(instance.primaryGrainFrame0 == .zero)
        #expect(instance.primaryGrainFrame1 == .zero)
        #expect(instance.secondaryGrainFrame0 == .zero)
        #expect(instance.secondaryGrainFrame1 == .zero)
        expectChannels(
            instance.premultipliedColor,
            SIMD4(0.3019137, 0.06643416, 0.01655238, 0.5)
        )
        #expect(instance.coverageInputs == SIMD4(0.6, 0.7, 0.8, 0.9))
        #expect(instance.clip0.normal == SIMD2(1, 0))
        #expect(instance.clip0.offset == -1)
        #expect(instance.clip0.padding == 0)
        #expect(instance.clip1.normal == SIMD2(0, 1))
        #expect(instance.clip1.offset == -2)
        #expect(instance.clip2.normal == SIMD2(-1, 0))
        #expect(instance.clip2.offset == -3)
        #expect(instance.clip3.normal == SIMD2(0, -1))
        #expect(instance.clip3.offset == -4)
        #expect(instance.identity.x == 0x7654_3210)
        #expect(instance.identity.y == 0xFEDC_BA98)
        #expect(instance.identity.z == 23)
        #expect(instance.identity.w == DepositionIdentityFlags.predicted)
        #expect(instance.metadata.x == 4)
        #expect(instance.metadata.y == DepositionShapeFlags.reflected)
        #expect(instance.metadata.z == 0)
        #expect(instance.metadata.w == UInt32(DepositionABI.version))
        #expect(instance.reserved0 == .zero)
        #expect(instance.reserved1 == .zero)
    }

    @Test
    func colorPackingDecodesAtBreakpointOnceAndZerosTransparentChroma() throws {
        let breakpoint = try PatternDepositionStampInstance(
            fragment: fragment(),
            dab: logicalDab(color: try #require(InkColor(
                red: 0.04045,
                green: 0.5,
                blue: 1,
                alpha: 0.5
            ))),
            logicalOrdinal: 0,
            isometryOrdinal: 0
        )
        expectChannels(
            breakpoint.premultipliedColor,
            SIMD4(0.0015654025, 0.10702057, 0.5, 0.5),
            tolerance: 2e-7
        )
        #expect(abs(breakpoint.premultipliedColor.y - 0.25) > 0.1)
        #expect(abs(breakpoint.premultipliedColor.y - 0.053510286) > 0.05)

        let transparent = try PatternDepositionStampInstance(
            fragment: fragment(),
            dab: logicalDab(color: try #require(InkColor(
                red: 1,
                green: 0.5,
                blue: 0.25,
                alpha: 0
            ))),
            logicalOrdinal: 1,
            isometryOrdinal: 0
        )
        #expect(transparent.premultipliedColor == .zero)
    }

    @Test
    func packsPrimaryAndSecondaryGrainFramesThroughTheSameIsometry() throws {
        let brushToWorld = Affine2D(
            xAxis: SIMD2(2, 0),
            yAxis: SIMD2(0, 3),
            translation: SIMD2(10, 20)
        )
        let worldToCanonical = Affine2D(
            xAxis: SIMD2(0, 1),
            yAxis: SIMD2(1, 0),
            translation: SIMD2(100, 200)
        )
        let fragment = fragment(
            canonicalFromBrush: brushToWorld.concatenating(worldToCanonical),
            reflected: true
        )
        let dab = logicalDab(
            brushToWorld: brushToWorld,
            primaryGrainToWorld: Affine2D(
                xAxis: SIMD2(4, 5),
                yAxis: SIMD2(6, 7),
                translation: SIMD2(8, 9)
            ),
            secondaryGrainToWorld: Affine2D(
                xAxis: SIMD2(-2, 3),
                yAxis: SIMD2(4, -5),
                translation: SIMD2(-6, 7)
            )
        )

        let instance = try PatternDepositionStampInstance(
            fragment: fragment,
            dab: dab,
            logicalOrdinal: 0,
            isometryOrdinal: 0
        )

        #expect(instance.primaryGrainFrame0 == SIMD4(5, 4, 7, 6))
        #expect(instance.primaryGrainFrame1 == SIMD4(109, 208, 0, 0))
        #expect(instance.secondaryGrainFrame0 == SIMD4(3, -2, -5, 4))
        #expect(instance.secondaryGrainFrame1 == SIMD4(107, 194, 0, 0))
        #expect(
            instance.metadata.z
                == DepositionGrainFlags.primary
                | DepositionGrainFlags.secondary
        )
    }

    @Test
    func zeroClipsAndAbsentGrainsProduceOnlyZeroWireFields() throws {
        let instance = try PatternDepositionStampInstance(
            fragment: fragment(),
            dab: logicalDab(),
            logicalOrdinal: 0,
            isometryOrdinal: 0
        )

        #expect(instance.metadata.x == 0)
        #expect(instance.metadata.z == 0)
        #expect(clipVector(instance.clip0) == .zero)
        #expect(clipVector(instance.clip1) == .zero)
        #expect(clipVector(instance.clip2) == .zero)
        #expect(clipVector(instance.clip3) == .zero)
        #expect(instance.primaryGrainFrame0 == .zero)
        #expect(instance.primaryGrainFrame1 == .zero)
        #expect(instance.secondaryGrainFrame0 == .zero)
        #expect(instance.secondaryGrainFrame1 == .zero)
    }

    @Test
    func clipPackingRejectsAnOverflowEvenIfTheUpstreamTypeChanges() {
        #expect(throws: DepositionStampPackingError.tooManyClipPlanes(
            actual: 5,
            maximum: 4
        )) {
            try DepositionStampPacker.validateClipPlaneCount(5)
        }
    }

    @Test
    func nonfinitePackedInputIsRejected() {
        let invalid = logicalDab(flow: .nan)

        #expect(throws: DepositionStampPackingError.nonfiniteField("flow")) {
            _ = try PatternDepositionStampInstance(
                fragment: fragment(),
                dab: invalid,
                logicalOrdinal: 0,
                isometryOrdinal: 0
            )
        }
    }

    @Test
    func projectedRecordEqualityChecksIdentityPageAndEveryWireField() throws {
        let firstInstance = try PatternDepositionStampInstance(
            fragment: fragment(),
            dab: logicalDab(),
            logicalOrdinal: 1,
            isometryOrdinal: 2
        )
        let secondInstance = try PatternDepositionStampInstance(
            fragment: fragment(),
            dab: logicalDab(flow: 0.25),
            logicalOrdinal: 1,
            isometryOrdinal: 2
        )
        let page = RadialPageCoordinate(x: -3, y: 8)
        let first = ProjectedDepositionRecord(
            identity: 9,
            instance: firstInstance,
            radialPage: page
        )

        #expect(first == ProjectedDepositionRecord(
            identity: 9,
            instance: firstInstance,
            radialPage: page
        ))
        #expect(first != ProjectedDepositionRecord(
            identity: 10,
            instance: firstInstance,
            radialPage: page
        ))
        #expect(first != ProjectedDepositionRecord(
            identity: 9,
            instance: firstInstance,
            radialPage: RadialPageCoordinate(x: -3, y: 9)
        ))
        #expect(first != ProjectedDepositionRecord(
            identity: 9,
            instance: secondInstance,
            radialPage: page
        ))
    }

    @Test
    @MainActor
    func metalDiagnosticRoundTripsFieldsAndRejectsForgedABIVersion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let valid = try PatternDepositionStampInstance(
            fragment: fragment(),
            dab: logicalDab(
                flow: 0.375,
                strokeOpacity: 0.625,
                ordinal: 0x0123_4567_89AB_CDEF
            ),
            logicalOrdinal: 0x0123_4567_89AB_CDEF,
            isometryOrdinal: 17
        )
        var forged = valid
        forged.metadata.w = UInt32(DepositionABI.version) + 1
        let inputs = [valid, forged]
        let library = try makeShaderLibrary(device: device)
        let function = try #require(
            library.makeFunction(name: "patternDepositionABIRoundTrip")
        )
        let pipeline = try device.makeComputePipelineState(function: function)
        let inputBuffer = try #require(device.makeBuffer(
            bytes: inputs,
            length: inputs.count
                * MemoryLayout<PatternDepositionStampInstance>.stride
        ))
        let wordCount = inputs.count * 7
        let outputBuffer = try #require(device.makeBuffer(
            length: wordCount * MemoryLayout<SIMD4<UInt32>>.stride
        ))
        let commandBuffer = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: inputs.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: inputs.count,
                height: 1,
                depth: 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        let output = Array(UnsafeBufferPointer(
            start: outputBuffer.contents()
                .assumingMemoryBound(to: SIMD4<UInt32>.self),
            count: wordCount
        ))
        #expect(output[0] == bitPatterns(valid.tipFrame0))
        #expect(output[1] == bitPatterns(valid.tipFrame1))
        #expect(output[2] == bitPatterns(valid.coverageInputs))
        #expect(output[3] == valid.identity)
        #expect(output[4] == valid.metadata)
        #expect(output[5] == .zero)
        #expect(output[6] == SIMD4(1, 256, 0, 0))
        #expect(output[11] == forged.metadata)
        #expect(output[13] == SIMD4(0, 256, 0, 0))
    }

    private func logicalDab(
        brushToWorld: Affine2D = .identity,
        radius: Float = 4,
        flow: Float = 1,
        strokeOpacity: Float = 1,
        hardness: Float = 1,
        color: InkColor = .black,
        materialContribution: Float = 1,
        ordinal: UInt64 = 0,
        isPredicted: Bool = false,
        primaryGrainToWorld: Affine2D? = nil,
        secondaryGrainToWorld: Affine2D? = nil
    ) -> LogicalDab {
        LogicalDab(
            position: WorldPoint(brushToWorld.translation),
            brushToWorld: brushToWorld,
            radius: radius,
            diameter: radius * 2,
            spacing: 1,
            flow: flow,
            strokeOpacity: strokeOpacity,
            rotation: 0,
            scatter: .zero,
            hardness: hardness,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: color,
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: materialContribution,
            sourceDistance: 0,
            ordinal: ordinal,
            isPredicted: isPredicted,
            primaryGrainToWorld: primaryGrainToWorld,
            secondaryGrainToWorld: secondaryGrainToWorld
        )
    }

    private func fragment(
        canonicalFromBrush: Affine2D = .identity,
        reflected: Bool = false
    ) -> CellFragment {
        CellFragment(
            cell: CellIndex(column: 0, row: 0),
            imageOrdinal: 0,
            canonicalFromBrush: canonicalFromBrush,
            brushClip: ConvexClip(halfPlanes: []),
            operation: CompiledGroupOperation(
                rotationStep: 0,
                rotationOrder: 1,
                reflected: reflected
            )
        )
    }

    private func clipVector(
        _ plane: PatternClipHalfPlane
    ) -> SIMD4<Float> {
        SIMD4(plane.normal.x, plane.normal.y, plane.offset, plane.padding)
    }

    private func bitPatterns(_ value: SIMD4<Float>) -> SIMD4<UInt32> {
        SIMD4(
            value.x.bitPattern,
            value.y.bitPattern,
            value.z.bitPattern,
            value.w.bitPattern
        )
    }

    private func expectChannels(
        _ actual: SIMD4<Float>,
        _ expected: SIMD4<Float>,
        tolerance: Float = 2e-7,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for channel in 0..<4 {
            #expect(
                abs(actual[channel] - expected[channel]) <= tolerance,
                sourceLocation: sourceLocation
            )
        }
    }

    private func makeShaderLibrary(
        device: any MTLDevice
    ) throws -> any MTLLibrary {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shader = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            encoding: .utf8
        )
        return try device.makeLibrary(
            source: shader.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
    }
}
