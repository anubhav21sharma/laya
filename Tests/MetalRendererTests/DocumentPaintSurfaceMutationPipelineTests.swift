import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import Testing

@Suite("Document paint mutation GPU foundation", .serialized)
@MainActor
struct DocumentPaintSurfaceMutationPipelineTests {
    @Test
    func createsAllProductionMutationPipelinesAndReportsMissingInputs() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeShaderLibrary(device: device)
        let binding = try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
            device: device,
            library: library
        )
        #expect(binding.stroke.threadExecutionWidth > 0)
        #expect(binding.resize.threadExecutionWidth > 0)
        #expect(binding.encodedImport.threadExecutionWidth > 0)

        #expect(
            throws: DocumentPaintSurfaceMutationPipelineError.libraryUnavailable
        ) {
            _ = try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
                device: device,
                library: nil
            )
        }
        let unrelated = try device.makeLibrary(
            source: "kernel void unrelated() {}",
            options: nil
        )
        #expect(
            throws: DocumentPaintSurfaceMutationPipelineError.functionUnavailable(
                "patternDocumentPaintStrokeMutation"
            )
        ) {
            _ = try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
                device: device,
                library: unrelated
            )
        }
    }

    @Test
    func strokeDrawErasePaddingAndStoredReductionMatchCPUReference() throws {
        guard let context = try makeContext() else { return }
        let base = try texture(context.device)
        let live = try texture(context.device)
        let destination = try texture(context.device)
        prefill(destination, with: SIMD4(0.2, 0.2, 0.2, 0.2))
        write([SIMD4<Float16>(0, 0, 0.5, 0.5)], to: base)
        write([SIMD4<Float16>(0.4, 0, 0, 0.5)], to: live)

        var uniforms = mutationUniforms(logicalExtent: SIMD2(1, 1))
        uniforms.compositeMode = PatternCompositeWireDraw
        uniforms.parameters = SIMD4(0.5, 0.25, 1, 0)
        let drawReduction = try run(
            context.binding.stroke,
            device: context.device,
            uniforms: uniforms,
            base: base,
            authoritative: live,
            destination: destination
        )
        expect(read(destination, x: 0, y: 0), SIMD4(0.1, 0, 0.4375, 0.5625))
        expect(read(destination, x: 1, y: 0), .zero)
        #expect(Float(bitPattern: drawReduction.maximumAlphaBits) == Float(Float16(0.5625)))
        #expect(drawReduction.invalid == 0)

        write([SIMD4<Float16>(0.4, 0.2, 0.1, 0.5)], to: base)
        write([SIMD4<Float16>(0, 0, 0, 0.25)], to: live)
        uniforms.compositeMode = PatternCompositeWireErase
        uniforms.parameters = SIMD4(1, 1, 0.5, 0)
        let eraseReduction = try run(
            context.binding.stroke,
            device: context.device,
            uniforms: uniforms,
            base: base,
            authoritative: live,
            destination: destination
        )
        expect(read(destination, x: 0, y: 0), SIMD4(0.35, 0.175, 0.0875, 0.4375))
        #expect(Float(bitPattern: eraseReduction.maximumAlphaBits) == Float(Float16(0.4375)))
        #expect(eraseReduction.invalid == 0)

        uniforms.flags = PatternDocumentPaintFlagBaseKnownClear
            | PatternDocumentPaintFlagAuthoritativeKnownClear
        let knownClear = try run(
            context.binding.stroke,
            device: context.device,
            uniforms: uniforms,
            destination: destination
        )
        expect(read(destination, x: 0, y: 0), .zero)
        #expect(knownClear.maximumAlphaBits == 0)
        #expect(knownClear.invalid == 0)

        uniforms.flags = 0
        write([SIMD4<Float16>(0, 0, 0, 0)], to: base)
        write([SIMD4<Float16>(.infinity, 0, 0, 1)], to: live)
        let nonfinite = try run(
            context.binding.stroke,
            device: context.device,
            uniforms: uniforms,
            base: base,
            authoritative: live,
            destination: destination
        )
        #expect(nonfinite.invalid == 1)
    }

    @Test
    func resizeCopiesOnlyRequestedRegionAndRadialMaskClearsOutsideCanvas() throws {
        guard let context = try makeContext() else { return }
        let source = try texture(context.device)
        let destination = try texture(context.device)
        prefill(destination, with: SIMD4(0.2, 0.2, 0.2, 0.2))
        write([
            SIMD4<Float16>(0.1, 0, 0, 0.1),
            SIMD4<Float16>(0, 0.2, 0, 0.2),
            SIMD4<Float16>(0, 0, 0.3, 0.3),
            SIMD4<Float16>(0.4, 0.4, 0, 0.4),
        ], to: source, width: 2, height: 2)
        var uniforms = mutationUniforms(logicalExtent: SIMD2(3, 3))
        uniforms.sourceOrigin = SIMD2(0, 0)
        uniforms.destinationOrigin = SIMD2(1, 1)
        uniforms.copyExtent = SIMD2(2, 2)
        let reduction = try run(
            context.binding.resize,
            device: context.device,
            uniforms: uniforms,
            base: source,
            destination: destination
        )
        expect(read(destination, x: 0, y: 0), .zero)
        expect(read(destination, x: 1, y: 1), SIMD4(0.1, 0, 0, 0.1))
        expect(read(destination, x: 2, y: 2), SIMD4(0.4, 0.4, 0, 0.4))
        expect(read(destination, x: 3, y: 2), .zero)
        #expect(Float(bitPattern: reduction.maximumAlphaBits) == Float(Float16(0.4)))

        uniforms = mutationUniforms(logicalExtent: SIMD2(3, 3))
        uniforms.copyExtent = SIMD2(3, 3)
        uniforms.flags = PatternDocumentPaintFlagRadialTargetMask
        var radial = PatternRadialFrameUniforms()
        radial.canvasSize = SIMD2(1, 1)
        radial.center = SIMD2(0.5, 0.5)
        radial.referenceAngle = 0
        radial.sectorAngle = 2 * .pi
        radial.displayedSectorCount = 1
        radial.dihedral = 0
        write(
            Array(
                repeating: SIMD4<Float16>(0.25, 0, 0, 0.25),
                count: 9
            ),
            to: source,
            width: 3,
            height: 3
        )
        _ = try run(
            context.binding.resize,
            device: context.device,
            uniforms: uniforms,
            radial: radial,
            base: source,
            destination: destination
        )
        expect(read(destination, x: 0, y: 0), SIMD4(0.25, 0, 0, 0.25))
        expect(read(destination, x: 1, y: 0), .zero)
    }

    @Test
    func encodedPremultipliedImportHonorsRowsAlphaZeroPaddingAndClamping() throws {
        guard let context = try makeContext() else { return }
        let destination = try texture(context.device)
        prefill(destination, with: SIMD4(0.2, 0.2, 0.2, 0.2))
        let bytes: [UInt8] = [
            1, 2, 3, 4,
            64, 16, 32, 128, 9, 8, 7, 0, 0xAA, 0xBB, 0xCC, 0xDD,
            0, 0, 128, 128, 0, 0, 0, 0, 0xEE, 0xFF, 0x11, 0x22,
        ]
        let source = try #require(context.device.makeBuffer(
            bytes: bytes,
            length: bytes.count
        ))
        var uniforms = mutationUniforms(logicalExtent: SIMD2(2, 2))
        uniforms.sourceBytesPerRow = 12
        uniforms.sourceByteOffset = 4
        let reduction = try run(
            context.binding.encodedImport,
            device: context.device,
            uniforms: uniforms,
            sourceBytes: source,
            destination: destination
        )
        expect(
            read(destination, x: 0, y: 0),
            SIMD4(0.02554, 0.00721, 0.1075, 0.502),
            tolerance: 0.001
        )
        expect(read(destination, x: 1, y: 0), .zero)
        expect(
            read(destination, x: 0, y: 1),
            SIMD4(0.502, 0, 0, 0.502),
            tolerance: 0.001
        )
        expect(read(destination, x: 2, y: 0), .zero)
        #expect(Float(bitPattern: reduction.maximumAlphaBits) == Float(Float16(Float(128) / 255)))
        #expect(reduction.invalid == 0)

        uniforms.sourceBytesPerRow = 4
        let channelAboveAlpha = try #require(context.device.makeBuffer(
            bytes: [UInt8](arrayLiteral: 255, 255, 255, 1),
            length: 4
        ))
        let clamped = try run(
            context.binding.encodedImport,
            device: context.device,
            uniforms: mutationUniforms(logicalExtent: SIMD2(1, 1), bytesPerRow: 4),
            sourceBytes: channelAboveAlpha,
            destination: destination
        )
        expect(
            read(destination, x: 0, y: 0),
            SIMD4<Float>(repeating: 1 / 255),
            tolerance: 0.00001
        )
        #expect(clamped.invalid == 0)
    }

    private func makeContext() throws -> (
        device: any MTLDevice,
        binding: DocumentPaintSurfaceMutationPipelineBinding
    )? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return (
            device,
            try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
                device: device,
                library: makeShaderLibrary(device: device)
            )
        )
    }

    private func makeShaderLibrary(device: any MTLDevice) throws -> any MTLLibrary {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let shader = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent(
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

    private func texture(_ device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 256,
            height: 256,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func mutationUniforms(
        logicalExtent: SIMD2<UInt32>,
        bytesPerRow: UInt32 = 0
    ) -> PatternDocumentPaintMutationUniforms {
        var value = PatternDocumentPaintMutationUniforms()
        value.logicalExtent = logicalExtent
        value.copyExtent = logicalExtent
        value.parameters = SIMD4(1, 1, 1, 0)
        value.sourceBytesPerRow = bytesPerRow
        return value
    }

    private func run(
        _ pipeline: any MTLComputePipelineState,
        device: any MTLDevice,
        uniforms: PatternDocumentPaintMutationUniforms,
        radial: PatternRadialFrameUniforms? = nil,
        base: (any MTLTexture)? = nil,
        authoritative: (any MTLTexture)? = nil,
        prediction: (any MTLTexture)? = nil,
        sourceBytes: (any MTLBuffer)? = nil,
        destination: any MTLTexture
    ) throws -> PatternDocumentPaintMutationReduction {
        let reduction = try #require(device.makeBuffer(length: 8, options: .storageModeShared))
        memset(reduction.contents(), 0, 8)
        let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        var uniforms = uniforms
        if prediction == nil {
            uniforms.flags |= PatternDocumentPaintFlagPredictionKnownClear
        }
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout.size(ofValue: uniforms),
            index: Int(PatternBufferIndexDocumentPaintMutationUniforms)
        )
        encoder.setBuffer(
            reduction,
            offset: 0,
            index: Int(PatternBufferIndexDocumentPaintMutationReduction)
        )
        encoder.setBuffer(
            sourceBytes,
            offset: 0,
            index: Int(PatternBufferIndexDocumentPaintMutationSourceBytes)
        )
        if var radial {
            encoder.setBytes(
                &radial,
                length: MemoryLayout.size(ofValue: radial),
                index: Int(PatternBufferIndexRadialFrameUniforms)
            )
        }
        encoder.setTexture(base, index: Int(PatternTextureIndexDocumentPaintBase))
        encoder.setTexture(authoritative, index: Int(PatternTextureIndexDocumentPaintAuthoritative))
        encoder.setTexture(prediction, index: Int(PatternTextureIndexDocumentPaintPrediction))
        encoder.setTexture(destination, index: Int(PatternTextureIndexDocumentPaintDestination))
        encoder.dispatchThreads(
            MTLSize(width: 256, height: 256, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return reduction.contents().load(as: PatternDocumentPaintMutationReduction.self)
    }

    private func write(
        _ pixels: [SIMD4<Float16>],
        to texture: any MTLTexture,
        width: Int = 1,
        height: Int = 1
    ) {
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * MemoryLayout<SIMD4<Float16>>.stride
        )
    }

    private func prefill(
        _ texture: any MTLTexture,
        with pixel: SIMD4<Float16>
    ) {
        write(
            Array(repeating: pixel, count: texture.width * texture.height),
            to: texture,
            width: texture.width,
            height: texture.height
        )
    }

    private func read(_ texture: any MTLTexture, x: Int, y: Int) -> SIMD4<Float> {
        var pixel = SIMD4<Float16>.zero
        texture.getBytes(
            &pixel,
            bytesPerRow: MemoryLayout<SIMD4<Float16>>.stride,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return SIMD4(Float(pixel.x), Float(pixel.y), Float(pixel.z), Float(pixel.w))
    }

    private func expect(
        _ actual: SIMD4<Float>,
        _ expected: SIMD4<Float>,
        tolerance: Float = 0.0006
    ) {
        for channel in 0..<4 {
            #expect(abs(actual[channel] - expected[channel]) <= tolerance)
        }
    }
}
