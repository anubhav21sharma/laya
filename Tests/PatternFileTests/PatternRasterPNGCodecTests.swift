import Foundation
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern raster PNG codec")
struct PatternRasterPNGCodecTests {
    @Test
    func premultipliedBGRABytesRoundTripWithoutOrientationChange() throws {
        let size = PixelSize(width: 4, height: 3)
        let pixels: [[UInt8]] = [
            [0, 0, 0, 0],
            [1, 1, 1, 1],
            [10, 20, 30, 64],
            [64, 32, 16, 64],
            [0, 0, 128, 128],
            [0, 128, 0, 128],
            [128, 0, 0, 128],
            [63, 127, 191, 255],
            [255, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 255, 255],
            [255, 255, 255, 255],
        ]
        let image = try PatternRasterImage(
            pixelSize: size,
            bgra8PremultipliedBytes: pixels.flatMap { $0 }
        )

        let encoded = try PatternRasterPNGCodec.encode(image)
        let decoded = try PatternRasterPNGCodec.decode(
            encoded,
            expectedPixelSize: size
        )

        #expect(decoded == image)
    }

    @Test
    func invalidInputAndUnexpectedDimensionsFailTyped() throws {
        #expect(
            throws: PatternRasterImageError.invalidByteCount(3)
        ) {
            try PatternRasterImage(
                pixelSize: PixelSize(width: 2, height: 2),
                bgra8PremultipliedBytes: [1, 2, 3]
            )
        }
        #expect(throws: PatternRasterImageError.invalidImage) {
            try PatternRasterPNGCodec.decode(Data("not an image".utf8))
        }

        let image = try PatternRasterImage(
            pixelSize: PixelSize(width: 2, height: 2),
            bgra8PremultipliedBytes: [
                0, 0, 0, 255,
                1, 2, 3, 255,
                4, 5, 6, 255,
                7, 8, 9, 255,
            ]
        )
        let encoded = try PatternRasterPNGCodec.encode(image)
        #expect(
            throws: PatternRasterImageError.unexpectedDimensions(
                expected: PixelSize(width: 3, height: 2),
                actualWidth: 2,
                actualHeight: 2
            )
        ) {
            try PatternRasterPNGCodec.decode(
                encoded,
                expectedPixelSize: PixelSize(width: 3, height: 2)
            )
        }
    }

    @Test
    func encodeRejectsRasterBeyondProjectDimensionLimit() throws {
        let image = try PatternRasterImage(
            pixelSize: PixelSize(width: 4_097, height: 1),
            bgra8PremultipliedBytes: [UInt8](
                repeating: 0,
                count: 4_097 * 4
            )
        )
        #expect(
            throws: PatternRasterImageError.invalidDimensions(
                width: 4_097,
                height: 1
            )
        ) {
            try PatternRasterPNGCodec.encode(image)
        }
    }

    @Test
    func deterministicPremultipliedCoverageMatrixIsByteExact() throws {
        let size = PixelSize(width: 64, height: 64)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size.width * size.height * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<(size.width * size.height) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let alpha = UInt8(truncatingIfNeeded: state >> 24)
            let divisor = UInt16(alpha) + 1
            let blue = UInt8(UInt16(state & 0xFF) % divisor)
            let green = UInt8(UInt16((state >> 8) & 0xFF) % divisor)
            let red = UInt8(UInt16((state >> 16) & 0xFF) % divisor)
            bytes.append(contentsOf: [blue, green, red, alpha])
        }
        let image = try PatternRasterImage(
            pixelSize: size,
            bgra8PremultipliedBytes: bytes
        )
        let decoded = try PatternRasterPNGCodec.decode(
            PatternRasterPNGCodec.encode(image),
            expectedPixelSize: size
        )
        #expect(decoded == image)
    }
}
