import Foundation
import Metal
import MetalKit

public struct GPUFrameMetrics: Codable, Equatable, Sendable {
    public let cpuEncodeMilliseconds: Double
    public let gpuMilliseconds: Double

    public init(
        cpuEncodeMilliseconds: Double,
        gpuMilliseconds: Double
    ) {
        self.cpuEncodeMilliseconds = cpuEncodeMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
    }
}

@MainActor
public struct RenderedFrame {
    public let texture: any MTLTexture
    public let metrics: GPUFrameMetrics
}

@MainActor
public final class BlankRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    public private(set) var lastError: MetalRendererError?

    private let commandQueue: any MTLCommandQueue
    private let pipelineState: any MTLRenderPipelineState

    public convenience init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(device: device, library: library)
    }

    public init(
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws {
        ShaderABI.preconditionValid()

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        guard let vertexFunction = library.makeFunction(name: "patternBlankVertex") else {
            throw MetalRendererError.shaderFunctionUnavailable("patternBlankVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "patternBlankFragment") else {
            throw MetalRendererError.shaderFunctionUnavailable("patternBlankFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Blank Canvas Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error.localizedDescription)
        }

        self.device = device
        self.commandQueue = commandQueue
        super.init()
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            lastError = .commandBufferUnavailable
            view.isPaused = true
            return
        }

        do {
            try encode(into: drawable.texture, commandBuffer: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch let error as MetalRendererError {
            lastError = error
            view.isPaused = true
        } catch {
            lastError = .commandFailed(error.localizedDescription)
            view.isPaused = true
        }
    }

    public func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {}

    public func renderOffscreen(
        width: Int,
        height: Int
    ) throws -> RenderedFrame {
        precondition((1...4096).contains(width), "Offscreen width is outside 1...4096")
        precondition((1...4096).contains(height), "Offscreen height is outside 1...4096")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let encodeStart = CFAbsoluteTimeGetCurrent()
        try encode(into: texture, commandBuffer: commandBuffer)
        let cpuMilliseconds = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1_000

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw MetalRendererError.commandFailed(
                commandBuffer.error?.localizedDescription ?? "unknown command-buffer error"
            )
        }

        let gpuMilliseconds = max(
            0,
            (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
        )
        return RenderedFrame(
            texture: texture,
            metrics: GPUFrameMetrics(
                cpuEncodeMilliseconds: cpuMilliseconds,
                gpuMilliseconds: gpuMilliseconds
            )
        )
    }

    private func encode(
        into texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }

        encoder.label = "Blank Canvas Pass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
