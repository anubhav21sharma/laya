import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Radial sector layout")
struct RadialSectorLayoutTests {
    @Test
    func sparseAccountingUsesResidentPagesRatherThanAtlasPadding() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 1_024,
            sectorAngleRadians: .pi
        )

        #expect(
            try layout.residentByteCount(bytesPerPixel: 8)
                == layout.residentPages.count * 256 * 256 * 8
        )
        #expect(
            try layout.pageTableByteCount(bytesPerEntry: 4)
                == layout.pageTable.count * 4
        )
        #expect(
            try layout.bindingSlotCount(projectedImageCount: 3)
                == layout.residentPages.count * 3
        )
        #expect(
            try layout.uploadWorkspaceByteCount(
                recordCount: 17,
                bytesPerRecord: 32
            ) == 544
        )
        #expect(
            try layout.residentByteCount(bytesPerPixel: 4)
                <= layout.residentBytesPerSurface
        )
    }

    @Test
    func sparseAccountingRejectsInvalidScalarsAndOverflow() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi
        )

        #expect(
            throws: RadialSectorAccountingError.nonpositiveElementSize(0)
        ) {
            _ = try layout.residentByteCount(bytesPerPixel: 0)
        }
        #expect(
            throws: RadialSectorAccountingError.negativeElementCount(-1)
        ) {
            _ = try layout.bindingSlotCount(projectedImageCount: -1)
        }
        #expect(throws: RadialSectorAccountingError.byteCountOverflow) {
            _ = try layout.pageTableByteCount(bytesPerEntry: Int.max)
        }
        #expect(throws: RadialSectorAccountingError.byteCountOverflow) {
            _ = try layout.uploadWorkspaceByteCount(
                recordCount: Int.max,
                bytesPerRecord: 2
            )
        }
    }

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
