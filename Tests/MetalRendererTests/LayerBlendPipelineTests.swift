import EditorCore
import Foundation
import Metal
import simd
import Testing
@testable import MetalRenderer

@Suite("Bounded GPU layer blend pipeline", .serialized)
struct LayerBlendPipelineTests {
    @Test @MainActor
    func gpuMatchesIndependentLinearPremultipliedReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLayerBlendLibrary(device: device)
        let pipeline = try LayerBlendPipeline.prepare(
            device: device,
            library: library,
            abiVersion: LayerBlendABI.version
        )
        let sourcePixels: [SIMD4<Float>] = [
            SIMD4(0.4, 0.1, 0.2, 0.5),
            SIMD4(0.0, 0.0, 0.0, 0.0),
            SIMD4(0.05, 0.3, 0.1, 0.4),
            SIMD4(0.7, 0.2, 0.05, 0.8),
        ]
        let backdropPixels: [SIMD4<Float>] = [
            SIMD4(0.1, 0.2, 0.3, 0.5),
            SIMD4(0.2, 0.1, 0.0, 0.25),
            SIMD4(0.3, 0.1, 0.2, 0.6),
            SIMD4(0.0, 0.0, 0.0, 0.0),
        ]
        let source = try makeTexture(device: device, pixels: sourcePixels)
        let backdrop = try makeTexture(
            device: device,
            pixels: backdropPixels
        )
        let target = try makeTexture(
            device: device,
            pixels: Array(repeating: .zero, count: 4)
        )
        let queue = try #require(device.makeCommandQueue())

        for mode in LayerBlendMode.allCases {
            for opacity: Float in [0, 0.5, 1] {
                let commandBuffer = try #require(queue.makeCommandBuffer())
                try pipeline.encode(
                    source: source,
                    backdrop: backdrop,
                    target: target,
                    opacity: opacity,
                    mode: mode,
                    commandBuffer: commandBuffer
                )
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                #expect(commandBuffer.status == .completed)

                let actual = readPixels(target)
                for index in actual.indices {
                    let bottom = try LayerDescriptor(
                        id: UUID(),
                        name: "Bottom"
                    )
                    let top = try LayerDescriptor(
                        id: UUID(),
                        name: "Top",
                        opacity: opacity,
                        blendMode: mode
                    )
                    let stack = try LayerStack(
                        layers: [bottom, top],
                        activeLayerID: top.id
                    )
                    let expected = LayerCPUCompositingReference.composite(
                        stack: stack
                    ) { layer in
                        layer.id == bottom.id
                            ? backdropPixels[index] : sourcePixels[index]
                    }
                    expectLayerBlendColor(
                        actual[index],
                        equals: expected,
                        tolerance: 2e-3
                    )
                }
            }
        }
    }

    @Test @MainActor
    func rejectsWrongABIAndTextureAliasBeforeEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLayerBlendLibrary(device: device)
        #expect(throws: LayerBlendPipelineError.unsupportedABI(0)) {
            _ = try LayerBlendPipeline.prepare(
                device: device,
                library: library,
                abiVersion: 0
            )
        }
        let pipeline = try LayerBlendPipeline.prepare(
            device: device,
            library: library,
            abiVersion: LayerBlendABI.version
        )
        let texture = try makeTexture(
            device: device,
            pixels: Array(repeating: .zero, count: 4)
        )
        let commandBuffer = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )
        #expect(throws: LayerBlendPipelineError.targetSourceAlias) {
            try pipeline.encode(
                source: texture,
                backdrop: texture,
                target: texture,
                opacity: 1,
                mode: .normal,
                commandBuffer: commandBuffer
            )
        }
    }

    @Test @MainActor
    func displayRejectsNonopaqueOrOutOfRangeClearColorBeforeEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pipeline = try LayerBlendPipeline.prepare(
            device: device,
            library: makeLayerBlendLibrary(device: device),
            abiVersion: LayerBlendABI.version
        )
        let source = try makeTexture(
            device: device,
            pixels: Array(repeating: .zero, count: 4)
        )
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.displayPixelFormat,
            width: 2,
            height: 2,
            mipmapped: false
        )
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = .renderTarget
        let target = try #require(device.makeTexture(
            descriptor: targetDescriptor
        ))
        let queue = try #require(device.makeCommandQueue())
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 2, maxY: 2
        )
        let invalidColors = [
            MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
            MTLClearColor(red: -0.1, green: 0, blue: 0, alpha: 1),
            MTLClearColor(red: 0, green: .infinity, blue: 0, alpha: 1),
            MTLClearColor(red: 0, green: 0, blue: 1.1, alpha: 1),
        ]

        for clearColor in invalidColors {
            let command = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearColor
            #expect(throws: LayerBlendPipelineError.invalidTexture) {
                try pipeline.encodeDisplay(
                    source: source,
                    target: target,
                    outputRegion: output,
                    parameters: .identity,
                    commandBuffer: command,
                    renderPassDescriptor: pass
                )
            }
        }
    }
}

private func makeTexture(
    device: any MTLDevice,
    pixels: [SIMD4<Float>]
) throws -> any MTLTexture {
    #expect(pixels.count == 4)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: 2,
        height: 2,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let encoded = pixels.flatMap { pixel in
        [pixel.x, pixel.y, pixel.z, pixel.w].map {
            Float16($0).bitPattern
        }
    }
    encoded.withUnsafeBytes { bytes in
        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: 2 * 4 * MemoryLayout<UInt16>.size
        )
    }
    return texture
}

private func readPixels(_ texture: any MTLTexture) -> [SIMD4<Float>] {
    var encoded = Array(repeating: UInt16(0), count: 2 * 2 * 4)
    encoded.withUnsafeMutableBytes { bytes in
        texture.getBytes(
            bytes.baseAddress!,
            bytesPerRow: 2 * 4 * MemoryLayout<UInt16>.size,
            from: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0
        )
    }
    return stride(from: 0, to: encoded.count, by: 4).map { offset in
        SIMD4(
            Float(Float16(bitPattern: encoded[offset])),
            Float(Float16(bitPattern: encoded[offset + 1])),
            Float(Float16(bitPattern: encoded[offset + 2])),
            Float(Float16(bitPattern: encoded[offset + 3]))
        )
    }
}

private func expectLayerBlendColor(
    _ actual: SIMD4<Float>,
    equals expected: SIMD4<Float>,
    tolerance: Float
) {
    for channel in 0..<4 {
        #expect(abs(actual[channel] - expected[channel]) <= tolerance)
    }
}

private func makeLayerBlendLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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
