import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Linear document color pipeline")
struct DocumentColorPipelineTests {
    @Test
    func declaresLinearWorkingAndEncodedDisplayFormats() {
        #expect(DocumentColorPipeline.workingPixelFormat == .rgba16Float)
        #expect(DocumentColorPipeline.displayPixelFormat == .bgra8Unorm_srgb)
    }

    @Test
    func fiftyPercentSourceOverUsesLinearPremultipliedArithmetic() throws {
        let source = try premultiplied(0.5, 0, 0, 0.5)
        let destination = try premultiplied(0, 0, 0.5, 0.5)

        #expect(
            DocumentColorPipeline.referenceSourceOver(
                source: source,
                destination: destination
            ).simd == SIMD4(0.5, 0, 0.25, 0.75)
        )
    }

    @Test
    func destinationOutScalesEveryPremultipliedChannelIncludingAlpha() throws {
        let destination = try premultiplied(0.4, 0.2, 0.1, 0.5)

        let erased = DocumentColorPipeline.referenceDestinationOut(
            destination: destination,
            eraseAlpha: 0.25
        )

        expectChannels(erased.simd, SIMD4(0.3, 0.15, 0.075, 0.375))
    }

    @Test
    func lowFlowBuildupMatchesOneEightAndSixtyFourSourceOverStamps() throws {
        let stamp = try premultiplied(
            0.0125,
            0.00625,
            0.003125,
            0.015625
        )
        let expected: [(Int, SIMD4<Float>)] = [
            (1, SIMD4(0.0125, 0.00625, 0.003125, 0.015625)),
            (8, SIMD4(
                0.09469885,
                0.04734942,
                0.02367471,
                0.118373565
            )),
            (64, SIMD4(
                0.5080108,
                0.2540054,
                0.1270027,
                0.63501346
            )),
        ]

        for (count, value) in expected {
            expectChannels(
                DocumentColorPipeline.referenceBuildup(
                    stamp: stamp,
                    count: count
                ).simd,
                value,
                tolerance: 2e-6
            )
        }
    }

    @Test
    func normalMultiplyAndScreenBlendInLinearLight() throws {
        let source = try premultiplied(0.2, 0.4, 0.8, 1)
        let destination = try premultiplied(0.5, 0.25, 0.1, 1)

        let expected: [(DocumentColorBlendMode, SIMD4<Float>)] = [
            (.normal, SIMD4(0.2, 0.4, 0.8, 1)),
            (.multiply, SIMD4(0.1, 0.1, 0.08, 1)),
            (.screen, SIMD4(0.6, 0.55, 0.82, 1)),
        ]

        for (mode, value) in expected {
            expectChannels(
                DocumentColorPipeline.referenceBlend(
                    source: source,
                    destination: destination,
                    mode: mode
                ).simd,
                value
            )
        }
    }

    @Test
    func packingRouteConvertsEncodedUIInputExactlyOnce() throws {
        let uiEncoded = try #require(EncodedSRGBColor(
            red: 0.5,
            green: 0.25,
            blue: 0.04045,
            alpha: 0.5
        ))

        let payload = DocumentColorPipeline.packShaderColor(uiEncoded)

        expectChannels(
            payload,
            SIMD4(0.10702057, 0.025438044, 0.0015654025, 0.5),
            tolerance: 2e-7
        )
        // These are the characteristic wrong values for encoded-space
        // premultiplication, double premultiplication, and gamma-decoded alpha.
        #expect(abs(payload.x - 0.25) > 0.1)
        #expect(abs(payload.x - 0.053510286) > 0.05)
        #expect(abs(payload.w - 0.21404114) > 0.25)
    }

    @Test
    func sourceOverAndDisplayRoundTripRejectEncodedSpaceMathAndDoubleEncode() throws {
        let source = try #require(EncodedSRGBColor(
            red: 0.5,
            green: 0,
            blue: 0,
            alpha: 0.5
        ))
        let destination = try #require(EncodedSRGBColor(
            red: 0,
            green: 0,
            blue: 0.5,
            alpha: 0.5
        ))
        let composited = DocumentColorPipeline.referenceSourceOver(
            source: source.linearPremultiplied(),
            destination: destination.linearPremultiplied()
        )
        let displayed = composited.encodedSRGB()

        expectChannels(
            composited.simd,
            SIMD4(0.10702057, 0, 0.053510286, 0.75),
            tolerance: 2e-7
        )
        #expect(abs(composited.red - 0.25) > 0.1)
        #expect(abs(displayed.red - 0.41372877) <= 2e-7)
        #expect(abs(displayed.red - 0.6757575) > 0.2)
        #expect(displayed.alpha == 0.75)
    }

    @Test
    @MainActor
    func metalHalfFloatHelpersMatchCPUForConversionCompositeBuildupAndErase() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeShaderLibrary(device: device)
        let function = try #require(
            library.makeFunction(name: "patternDocumentColorDifferential")
        )
        let pipeline = try device.makeComputePipelineState(function: function)
        let conversion = try #require(EncodedSRGBColor(
            red: 0.5,
            green: 0.25,
            blue: 0.04045,
            alpha: 0.5
        ))
        let source = try premultiplied(0.5, 0, 0, 0.5)
        let destination = try premultiplied(0, 0, 0.5, 0.5)
        let stamp = try premultiplied(
            0.0125,
            0.00625,
            0.003125,
            0.015625
        )
        let eraseDestination = try premultiplied(0.4, 0.2, 0.1, 0.5)
        let inputs = [
            MetalDocumentColorProbeInput(
                source: conversion.simd,
                destination: .zero,
                controls: SIMD4(0, 0, 0, 0)
            ),
            MetalDocumentColorProbeInput(
                source: source.simd,
                destination: destination.simd,
                controls: SIMD4(1, 0, 0, 0)
            ),
            MetalDocumentColorProbeInput(
                source: stamp.simd,
                destination: .zero,
                controls: SIMD4(2, 64, 0, 0)
            ),
            MetalDocumentColorProbeInput(
                source: SIMD4(0, 0, 0, 0.25),
                destination: eraseDestination.simd,
                controls: SIMD4(3, 0, 0, 0)
            ),
        ]
        let expected = [
            conversion.linearPremultiplied().simd,
            DocumentColorPipeline.referenceSourceOver(
                source: source,
                destination: destination
            ).simd,
            DocumentColorPipeline.referenceBuildup(
                stamp: stamp,
                count: 64
            ).simd,
            DocumentColorPipeline.referenceDestinationOut(
                destination: eraseDestination,
                eraseAlpha: 0.25
            ).simd,
        ]

        let actual = try runMetalProbe(
            inputs: inputs,
            device: device,
            pipeline: pipeline
        )

        #expect(actual.count == expected.count)
        for (actual, expected) in zip(actual, expected) {
            expectChannels(actual, expected, tolerance: 2e-3)
        }
    }

    private func premultiplied(
        _ red: Float,
        _ green: Float,
        _ blue: Float,
        _ alpha: Float
    ) throws -> LinearPremultipliedColor {
        try #require(LinearPremultipliedColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        ))
    }

    private func expectChannels(
        _ actual: SIMD4<Float>,
        _ expected: SIMD4<Float>,
        tolerance: Float = 1e-7
    ) {
        for channel in 0..<4 {
            #expect(abs(actual[channel] - expected[channel]) <= tolerance)
        }
    }

    @MainActor
    private func makeShaderLibrary(
        device: any MTLDevice
    ) throws -> any MTLLibrary {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
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
            source: source.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
    }

    @MainActor
    private func runMetalProbe(
        inputs: [MetalDocumentColorProbeInput],
        device: any MTLDevice,
        pipeline: any MTLComputePipelineState
    ) throws -> [SIMD4<Float>] {
        let inputBuffer = try #require(device.makeBuffer(
            bytes: inputs,
            length: inputs.count
                * MemoryLayout<MetalDocumentColorProbeInput>.stride
        ))
        let outputBuffer = try #require(device.makeBuffer(
            length: inputs.count * MemoryLayout<SIMD4<Float16>>.stride
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

        let halfValues = Array(UnsafeBufferPointer(
            start: outputBuffer.contents().assumingMemoryBound(
                to: SIMD4<Float16>.self
            ),
            count: inputs.count
        ))
        return halfValues.map { value in
            SIMD4(
                Float(value.x),
                Float(value.y),
                Float(value.z),
                Float(value.w)
            )
        }
    }
}

private struct MetalDocumentColorProbeInput {
    var source: SIMD4<Float>
    var destination: SIMD4<Float>
    var controls: SIMD4<UInt32>
}
