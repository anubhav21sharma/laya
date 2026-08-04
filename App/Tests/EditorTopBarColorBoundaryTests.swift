import PatternEngine
import SwiftUI
import Testing

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@Suite("Editor top-bar color boundary")
struct EditorTopBarColorBoundaryTests {
    @Test
    @MainActor
    func arbitrarySourceSpacesBecomeBoundedEncodedSRGBWithPreservedAlpha() throws {
        #if os(macOS)
        let sourceColors: [(Color, Float)] = [
            (Color(NSColor(
                colorSpace: .displayP3,
                components: [1, 0.15, 0.4, 0.35],
                count: 4
            )), 0.35),
            (Color(NSColor(
                colorSpace: .genericGray,
                components: [0.6, 0.65],
                count: 2
            )), 0.65),
        ]
        #elseif os(iOS)
        let sourceColors: [(Color, Float)] = [
            (Color(UIColor(
                displayP3Red: 1,
                green: 0.15,
                blue: 0.4,
                alpha: 0.35
            )), 0.35),
            (Color(UIColor(white: 0.6, alpha: 0.65)), 0.65),
        ]
        #endif

        for (source, sourceAlpha) in sourceColors {
            let encoded = try #require(
                EditorTopBar.encodedSRGBColor(from: source)
            )
            #expect((0...1).contains(encoded.red))
            #expect((0...1).contains(encoded.green))
            #expect((0...1).contains(encoded.blue))
            #expect((0...1).contains(encoded.alpha))
            #expect(abs(encoded.alpha - sourceAlpha) <= 1e-6)
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
