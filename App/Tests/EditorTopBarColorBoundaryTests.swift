import AppKit
import PatternEngine
import SwiftUI
import Testing

@Suite("Editor top-bar color boundary")
struct EditorTopBarColorBoundaryTests {
    @Test
    @MainActor
    func arbitrarySourceSpacesBecomeBoundedEncodedSRGBWithPreservedAlpha() throws {
        let sourceColors = [
            NSColor(
                colorSpace: .displayP3,
                components: [1.1, 0.2, 0.4, 0.35],
                count: 4
            ),
            NSColor(
                colorSpace: .genericGray,
                components: [0.6, 0.65],
                count: 2
            ),
            NSColor(
                deviceCyan: 0.2,
                magenta: 0.7,
                yellow: 0.1,
                black: 0.05,
                alpha: 0.8
            ),
        ]

        for source in sourceColors {
            let encoded = try #require(
                EditorTopBar.encodedSRGBColor(from: Color(source))
            )
            #expect((0...1).contains(encoded.red))
            #expect((0...1).contains(encoded.green))
            #expect((0...1).contains(encoded.blue))
            #expect((0...1).contains(encoded.alpha))
            #expect(abs(encoded.alpha - Float(source.alphaComponent)) <= 1e-6)
        }
    }

    @Test
    @MainActor
    func encodedSRGBBoundaryDoesNotDecodeGammaOrPremultiply() throws {
        let source = Color(
            .sRGB,
            red: 0.5,
            green: 0.25,
            blue: 0.04045,
            opacity: 0.5
        )

        let encoded = try #require(
            EditorTopBar.encodedSRGBColor(from: source)
        )
        let ink = encoded.inkColor

        #expect(abs(encoded.red - 0.5) <= 1e-6)
        #expect(abs(encoded.green - 0.25) <= 1e-6)
        #expect(abs(encoded.blue - 0.04045) <= 1e-6)
        #expect(abs(encoded.alpha - 0.5) <= 1e-6)
        #expect(ink.simd == encoded.simd)
        #expect(abs(encoded.red - 0.21404114) > 0.25)
        #expect(abs(encoded.red - 0.25) > 0.2)
    }
}
