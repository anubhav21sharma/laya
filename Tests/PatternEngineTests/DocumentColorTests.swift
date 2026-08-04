import PatternEngine
import Testing

@Suite("Document color semantics")
struct DocumentColorTests {
    @Test
    func typedColorsRejectNonfiniteAndOutOfBoundsComponents() {
        #expect(EncodedSRGBColor(
            red: 0.2,
            green: 0.4,
            blue: 0.6,
            alpha: 0.8
        ) != nil)
        #expect(EncodedSRGBColor(
            red: .nan,
            green: 0,
            blue: 0,
            alpha: 1
        ) == nil)
        #expect(LinearUnpremultipliedColor(
            red: 0,
            green: -.infinity,
            blue: 0,
            alpha: 1
        ) == nil)
        #expect(LinearPremultipliedColor(
            red: 0.51,
            green: 0,
            blue: 0,
            alpha: 0.5
        ) == nil)
        #expect(LinearPremultipliedColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1.01
        ) == nil)
    }

    @Test
    func blackWhiteAndTransferBreakpointsUseIEC6196621() throws {
        let black = try #require(EncodedSRGBColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        ))
        let white = try #require(EncodedSRGBColor(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1
        ))
        #expect(black.linearPremultiplied().simd == SIMD4(0, 0, 0, 1))
        #expect(white.linearPremultiplied().simd == SIMD4(1, 1, 1, 1))

        let encodedBreakpoint = try #require(EncodedSRGBColor(
            red: 0.04045,
            green: 0,
            blue: 0,
            alpha: 1
        ))
        #expect(
            abs(encodedBreakpoint.linearPremultiplied().red
                - 0.003130805) <= 1e-7
        )

        let linearBreakpoint = try #require(LinearPremultipliedColor(
            red: 0.0031308,
            green: 0,
            blue: 0,
            alpha: 1
        ))
        #expect(
            abs(linearBreakpoint.encodedSRGB().red
                - 0.040449936) <= 1e-7
        )
    }

    @Test
    func alphaIsNeverTransferredAndPremultiplicationHappensInLinearLight() throws {
        for alpha: Float in [0, 0.5, 1] {
            let encoded = try #require(EncodedSRGBColor(
                red: 0.5,
                green: 0.25,
                blue: 0.04045,
                alpha: alpha
            ))
            let linear = encoded.linearPremultiplied()
            #expect(linear.alpha == alpha)
            #expect(abs(linear.red - 0.21404114 * alpha) <= 1e-7)
            #expect(abs(linear.green - 0.05087609 * alpha) <= 1e-7)
            #expect(abs(linear.blue - 0.003130805 * alpha) <= 1e-7)
        }
    }

    @Test
    func transparentNonzeroEncodedRGBBecomesTransparentBlack() throws {
        let encoded = try #require(EncodedSRGBColor(
            red: 1,
            green: 0.5,
            blue: 0.25,
            alpha: 0
        ))

        #expect(encoded.linearPremultiplied().simd == .zero)
        #expect(encoded.linearPremultiplied().encodedSRGB().simd == .zero)
    }

    @Test
    func encodedRoundTripStaysWithinOneEightBitStep() throws {
        let colors = try [
            EncodedSRGBColor(red: 0, green: 0, blue: 0, alpha: 0),
            EncodedSRGBColor(
                red: 0.003,
                green: 0.04045,
                blue: 0.25,
                alpha: 0.5
            ),
            EncodedSRGBColor(
                red: 0.18,
                green: 0.5,
                blue: 0.9,
                alpha: 1
            ),
            EncodedSRGBColor(red: 1, green: 1, blue: 1, alpha: 1),
        ].map { try #require($0) }

        for color in colors {
            let roundTrip = color.linearPremultiplied().encodedSRGB()
            #expect(abs(roundTrip.red - color.red) <= 1 / 255)
            #expect(abs(roundTrip.green - color.green) <= 1 / 255)
            #expect(abs(roundTrip.blue - color.blue) <= 1 / 255)
            #expect(roundTrip.alpha == color.alpha)
        }
    }

    @Test
    func encodedColorBridgesToEncodedInkColorWithoutTransfer() throws {
        let encoded = try #require(EncodedSRGBColor(
            red: 0.5,
            green: 0.25,
            blue: 0.75,
            alpha: 0.4
        ))
        let ink = encoded.inkColor

        #expect(ink.simd == SIMD4(0.5, 0.25, 0.75, 0.4))
        #expect(EncodedSRGBColor(ink).simd == encoded.simd)
    }
}
