import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Radial sector layout")
struct RadialSectorLayoutTests {
    @Test
    func pageAtlasAllocatesOnlySectorIntersectingPages() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 1_024,
            sectorAngleRadians: .pi
        )

        #expect(layout.residentPages.count < layout.pageTable.count)
        #expect(layout.residentPages.map(\.atlasSlot)
            == Array(layout.residentPages.indices))
        #expect(layout.residentBytesPerSurface
            == layout.atlasPixelSize.width
                * layout.atlasPixelSize.height * 4)
        #expect(layout.atlasPixelSize.width
            <= RadialSectorLayout.maximumAtlasDimension)
        #expect(layout.atlasPixelSize.height
            <= RadialSectorLayout.maximumAtlasDimension)
    }

    @Test
    func logicalPageLookupAndAtlasMappingAreDeterministic() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 700,
            sectorAngleRadians: .pi / 3
        )
        let probes = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(255.5, 1),
            SIMD2<Float>(300, 300),
        ]

        for point in probes where layout.containsLogicalPoint(point) {
            let page = try #require(layout.residentPage(containing: point))
            let atlas = try #require(layout.atlasPoint(forLogical: point))
            #expect(layout.logicalToAtlas(for: page).applying(to: point)
                == atlas)
            #expect(atlas.x >= 0)
            #expect(atlas.y >= 0)
            #expect(atlas.x < Float(layout.atlasPixelSize.width))
            #expect(atlas.y < Float(layout.atlasPixelSize.height))
        }
    }

    @Test
    func sectorMaskUsesRadiusAndBothAxes() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 100,
            sectorAngleRadians: .pi / 4
        )

        #expect(layout.containsLogicalPoint(SIMD2(50, 20)))
        #expect(!layout.containsLogicalPoint(SIMD2(20, 50)))
        #expect(!layout.containsLogicalPoint(SIMD2(90, 90)))
        #expect(layout.containsLogicalPoint(.zero))
    }
}
