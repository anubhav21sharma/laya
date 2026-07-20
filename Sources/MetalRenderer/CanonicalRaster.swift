import Metal
import PatternEngine

public final class CanonicalRaster: RasterSurface {
    public let pixelSize: PixelSize
    public private(set) var revision: RasterRevision
    public private(set) var front: any MTLTexture
    public private(set) var scratch: any MTLTexture

    public init(
        device: any MTLDevice,
        pixelSize: PixelSize,
        initialRevision: RasterRevision = RasterRevision(rawValue: 0)
    ) throws {
        self.pixelSize = pixelSize
        revision = initialRevision

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]

        guard
            let front = device.makeTexture(descriptor: descriptor),
            let scratch = device.makeTexture(descriptor: descriptor)
        else {
            throw MetalRendererError.textureAllocationFailed
        }

        front.label = "Canonical Front"
        scratch.label = "Canonical Scratch"
        self.front = front
        self.scratch = scratch
    }

    public func acceptScratchCommit() {
        swap(&front, &scratch)
        revision = revision.advanced()
    }
}
