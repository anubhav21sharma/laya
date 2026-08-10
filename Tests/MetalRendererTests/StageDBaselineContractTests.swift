import Foundation
import Testing

@Suite("External encoded-color references")
struct StageDBaselineContractTests {
    @Test
    func encodedImportFixturesHaveIndependentLinearReferences() {
        for fixture in stageDImportFixtures {
            #expect(fixture.encodedBGRA8.count == 4)
            #expect(fixture.linearReference.count == 4)
            let actual = stageDDecodeEncodedBGRA8(fixture.encodedBGRA8)
            for (actual, expected) in zip(actual, fixture.linearReference) {
                #expect(
                    abs(actual - expected) < 1e-9,
                    Comment(rawValue: fixture.name)
                )
            }
        }
    }
}

private struct StageDEncodedImportFixture: Sendable {
    let name: String
    let encodedBGRA8: [UInt8]
    /// Hand-derived from IEC 61966-2-1 decode; alpha is never gamma encoded.
    let linearReference: [Double]
}

private let stageDImportFixtures: [StageDEncodedImportFixture] = [
    .init(name: "empty", encodedBGRA8: [0, 0, 0, 0], linearReference: [0, 0, 0, 0]),
    .init(
        name: "translucent",
        encodedBGRA8: [32, 64, 128, 128],
        linearReference: [
            0.014443843596, 0.051269458374, 0.215860500114,
            128.0 / 255.0,
        ]
    ),
    .init(
        name: "low-flow-repeated-buildup",
        encodedBGRA8: [16, 32, 64, 96],
        linearReference: [
            0.005181516702, 0.014443843596, 0.051269458374,
            96.0 / 255.0,
        ]
    ),
    .init(
        name: "erase",
        encodedBGRA8: [24, 48, 96, 160],
        linearReference: [
            0.009134058702, 0.029556834438, 0.116970667759,
            160.0 / 255.0,
        ]
    ),
    .init(
        name: "periodic-seam",
        encodedBGRA8: [255, 0, 255, 255],
        linearReference: [1, 0, 1, 1]
    ),
    .init(
        name: "radial-pages",
        encodedBGRA8: [12, 180, 240, 224],
        linearReference: [
            0.003676507324, 0.456411023180, 0.871367119199,
            224.0 / 255.0,
        ]
    ),
]

private func stageDDecodeEncodedBGRA8(_ encoded: [UInt8]) -> [Double] {
    encoded.enumerated().map { index, byte in
        let value = Double(byte) / 255
        if index == 3 { return value }
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}
