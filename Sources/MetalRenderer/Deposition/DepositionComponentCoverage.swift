import Metal

enum DepositionComponentCoverage {
    static let pixelFormat: MTLPixelFormat = .rg16Float
    static let bytesPerPixel = 4

    static func textureDescriptor(
        width: Int,
        height: Int
    ) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return descriptor
    }

    static func residentByteCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(
            by: bytesPerPixel
        )
        return pixelOverflow || byteOverflow ? nil : bytes
    }
}
