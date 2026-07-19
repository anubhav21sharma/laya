import Metal
import PatternEngine

@MainActor
public final class PersistentLiveTile {
    public let texture: any MTLTexture
    public private(set) var isVisible = false
    public private(set) var isDirty = false

    public init(device: any MTLDevice, pixelSize: PixelSize) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }

        texture.label = "Persistent Live Stroke"
        self.texture = texture
    }

    public func markStamped() {
        isVisible = true
        isDirty = true
    }

    public func hide() {
        isVisible = false
    }

    public func markCleared() {
        isVisible = false
        isDirty = false
    }
}
