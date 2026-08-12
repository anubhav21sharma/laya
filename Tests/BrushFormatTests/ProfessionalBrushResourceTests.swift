import BrushFormat
import Foundation
import PatternEngine
import Testing

@Suite("Professional brush resources")
struct ProfessionalBrushResourceTests {
    @Test
    func bundledResourcesMatchPinnedBytesAndQuality() throws {
        #expect(ProfessionalBrushResources.descriptors.count == 7)
        #expect(
            Set(ProfessionalBrushResources.descriptors.map(\.id)).count == 7
        )
        for resource in ProfessionalBrushResources.descriptors {
            let data = try ProfessionalBrushResources.data(for: resource.id)
            #expect(data.count == resource.byteCount)
            #expect(BrushContentHash.sha256Hex(of: data) == resource.sha256)
            let measurement = try ProfessionalBrushResourceQuality.validate(
                bytes: [UInt8](data),
                width: resource.dimension,
                height: resource.dimension,
                kind: resource.kind
            )
            #expect(measurement.maximum > measurement.minimum)
            #expect(measurement.variance > 0)
        }
    }

    @Test
    func resourceQualityNegativeControlsFailIndependently() throws {
        let size = 64
        let blank = [UInt8](repeating: 0, count: size * size)
        #expect(throws: ProfessionalBrushResourceQualityError.self) {
            _ = try validate(blank, size: size, kind: .shape)
        }

        var onePixel = blank
        onePixel[(size / 2) * size + size / 2] = 255
        #expect(throws: ProfessionalBrushResourceQualityError.self) {
            _ = try validate(onePixel, size: size, kind: .shape)
        }

        var clipped = blank
        for y in 0..<size {
            for x in 0..<(size / 2) { clipped[y * size + x] = 255 }
        }
        #expect(throws: ProfessionalBrushResourceQualityError.self) {
            _ = try validate(clipped, size: size, kind: .shape)
        }

        let hardSeam = (0..<(size * size)).map {
            $0 % size == size - 1 ? UInt8(255) : UInt8(96)
        }
        #expect(throws: ProfessionalBrushResourceQualityError.self) {
            _ = try validate(hardSeam, size: size, kind: .grain)
        }

        let stripe = (0..<(size * size)).map {
            ($0 % size).isMultiple(of: 2) ? UInt8(96) : UInt8(255)
        }
        #expect(throws: ProfessionalBrushResourceQualityError.self) {
            _ = try validate(stripe, size: size, kind: .grain)
        }

        #expect(throws: ProfessionalBrushResourceQualityError.self) {
            _ = try ProfessionalBrushResourceQuality.validate(
                bytes: [UInt8](repeating: 128, count: 8 * 8),
                width: 8,
                height: 8,
                kind: .grain
            )
        }
    }

    private func validate(
        _ bytes: [UInt8],
        size: Int,
        kind: BrushResourceKind
    ) throws -> ProfessionalBrushResourceQualityMeasurement {
        try ProfessionalBrushResourceQuality.validate(
            bytes: bytes,
            width: size,
            height: size,
            kind: kind
        )
    }
}
