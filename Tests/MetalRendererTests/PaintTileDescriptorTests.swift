import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Paint tile descriptor")
struct PaintTileDescriptorTests {
    @Test
    func physicalContractAndClippedEdgeBoundsStayFixed() throws {
        #expect(PaintTileDescriptor.side == 256)
        #expect(PaintTileDescriptor.pixelFormat == .rgba16Float)
        #expect(PaintTileDescriptor.residentByteCount == 524_288)

        let descriptor = try PaintTileDescriptor(
            coordinate: PaintTileCoordinate(x: 1, y: 1),
            logicalPixelSize: PixelSize(width: 300, height: 270)
        )

        #expect(descriptor.physicalPixelSize == PixelSize(width: 256, height: 256))
        #expect(descriptor.logicalBounds == PixelRect(minX: 256, minY: 256, maxX: 300, maxY: 270))
        #expect(descriptor.residentByteCount == 524_288)
    }

    @Test
    func coordinatesAreOrderedByRowThenColumn() {
        let values = [
            PaintTileCoordinate(x: 2, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 0),
        ]

        #expect(values.sorted() == [
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 2, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
        ])
    }

    @Test
    func pointLookupRejectsNegativeAndOutOfRangeInputs() throws {
        let size = PixelSize(width: 512, height: 300)
        #expect(
            try PaintTileDescriptor.coordinate(containingX: 0, y: 0, in: size)
                == PaintTileCoordinate(x: 0, y: 0)
        )
        #expect(
            try PaintTileDescriptor.coordinate(containingX: 511, y: 299, in: size)
                == PaintTileCoordinate(x: 1, y: 1)
        )
        #expect(throws: PaintTileError.pixelOutsideSurface(x: -1, y: 0)) {
            _ = try PaintTileDescriptor.coordinate(containingX: -1, y: 0, in: size)
        }
        #expect(throws: PaintTileError.pixelOutsideSurface(x: 0, y: -1)) {
            _ = try PaintTileDescriptor.coordinate(containingX: 0, y: -1, in: size)
        }
        #expect(throws: PaintTileError.pixelOutsideSurface(x: 512, y: 0)) {
            _ = try PaintTileDescriptor.coordinate(containingX: 512, y: 0, in: size)
        }
        #expect(throws: PaintTileError.pixelOutsideSurface(x: 0, y: 300)) {
            _ = try PaintTileDescriptor.coordinate(containingX: 0, y: 300, in: size)
        }
        #expect(throws: PaintTileError.coordinateOutsideSurface(.init(x: -1, y: 0))) {
            _ = try PaintTileDescriptor(
                coordinate: PaintTileCoordinate(x: -1, y: 0),
                logicalPixelSize: size
            )
        }
        #expect(throws: PaintTileError.coordinateOutsideSurface(.init(x: 2, y: 0))) {
            _ = try PaintTileDescriptor(
                coordinate: PaintTileCoordinate(x: 2, y: 0),
                logicalPixelSize: size
            )
        }
    }

    @Test
    func antialiasHaloExpandsAcrossSeamAndDabOrEraserFourTileCorner() throws {
        let size = PixelSize(width: 1024, height: 1024)
        let seam = try PaintTileDescriptor.coordinates(
            intersecting: try #require(PixelRect(minX: 255, minY: 40, maxX: 256, maxY: 50)),
            in: size,
            antialiasHalo: 1
        )
        #expect(seam == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ])

        let corner = try PaintTileDescriptor.coordinates(
            intersecting: try #require(PixelRect(minX: 256, minY: 256, maxX: 257, maxY: 257)),
            in: size,
            antialiasHalo: 1
        )
        #expect(corner == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ])
    }

    @Test
    func boundsOutsideSurfaceClipOrReturnEmptyAndInvalidHaloFails() throws {
        let size = PixelSize(width: 300, height: 300)
        #expect(try PaintTileDescriptor.coordinates(
            intersecting: try #require(PixelRect(minX: -20, minY: -20, maxX: 2, maxY: 2)),
            in: size,
            antialiasHalo: 1
        ) == [PaintTileCoordinate(x: 0, y: 0)])
        #expect(try PaintTileDescriptor.coordinates(
            intersecting: try #require(PixelRect(minX: -20, minY: 30, maxX: -10, maxY: 40)),
            in: size,
            antialiasHalo: 1
        ).isEmpty)
        #expect(throws: PaintTileError.invalidAntialiasHalo(-1)) {
            _ = try PaintTileDescriptor.coordinates(
                intersecting: try #require(PixelRect(minX: 1, minY: 1, maxX: 2, maxY: 2)),
                in: size,
                antialiasHalo: -1
            )
        }
    }
}
