import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint encoded import boundary")
struct DocumentPaintEncodedImportSourceTests {
    @Test
    func paddedSingleRasterIsPackedIntoSparsePhysicalTiles() throws {
        let geometry = try importGeometry(width: 257, height: 2)
        let stride = 257 * 4 + 12
        var bytes = Data(repeating: 0, count: stride * 2)
        setImportPixel(&bytes, stride: stride, x: 0, y: 0,
                       bgra: [9, 7, 5, 0])
        setImportPixel(&bytes, stride: stride, x: 256, y: 1,
                       bgra: [3, 4, 5, 128])

        let request = try DocumentPaintSurfaceEncodedImportRequest.validate(
            layerID: UUID(),
            candidateGeometry: geometry,
            input: .singleRaster(.init(
                width: 257,
                height: 2,
                bytesPerRow: stride,
                bytes: bytes
            )),
            maximumUploadBytes: 8
        )

        #expect(request.importDirtyCoordinates == [.init(x: 1, y: 0)])
        #expect(request.importTotalEncodedByteCount == 8)
    }

    @Test
    func invalidRawPlaneAndPackedBudgetFailAtBoundary() throws {
        let geometry = try importGeometry(width: 2, height: 1)
        let layerID = UUID()

        #expect(throws: DocumentPaintEncodedImportError.invalidDimensions(
            width: 0, height: 1
        )) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: 0, height: 1, bytesPerRow: 0, bytes: Data()
                )),
                maximumUploadBytes: 8
            )
        }
        #expect(throws: DocumentPaintEncodedImportError.invalidRowStride(
            minimum: 8, actual: 7
        )) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: 2,
                    height: 1,
                    bytesPerRow: 7,
                    bytes: Data(repeating: 0, count: 7)
                )),
                maximumUploadBytes: 8
            )
        }
        #expect(throws: DocumentPaintEncodedImportError.invalidByteCount(
            expected: 8, actual: 7
        )) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: 2,
                    height: 1,
                    bytesPerRow: 8,
                    bytes: Data(repeating: 0, count: 7)
                )),
                maximumUploadBytes: 8
            )
        }
        #expect(throws: DocumentPaintEncodedImportError.byteCountOverflow) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: Int.max,
                    height: 2,
                    bytesPerRow: Int.max,
                    bytes: Data()
                )),
                maximumUploadBytes: 8
            )
        }
        #expect(throws: DocumentPaintEncodedImportError.uploadBudgetExceeded(
            required: 8, maximum: 7
        )) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: 2,
                    height: 1,
                    bytesPerRow: 8,
                    bytes: Data([1, 2, 3, 255, 4, 5, 6, 255])
                )),
                maximumUploadBytes: 7
            )
        }

        let twoTileGeometry = try importGeometry(width: 512, height: 256)
        let oneTileBytes = 256 * 256 * 4
        #expect(throws: DocumentPaintEncodedImportError.uploadBudgetExceeded(
            required: oneTileBytes * 2,
            maximum: oneTileBytes
        )) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: layerID,
                candidateGeometry: twoTileGeometry,
                input: .singleRaster(.init(
                    width: 512,
                    height: 256,
                    bytesPerRow: 2_048,
                    bytes: Data(repeating: 255, count: oneTileBytes * 2)
                )),
                maximumUploadBytes: oneTileBytes
            )
        }
    }

    @Test
    func radialPagesMapSignedCoordinatesAndSortByPhysicalDestination() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 700,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 700, height: 700),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let selected = [layout.residentPages.last!, layout.residentPages.first!]
        let opaquePage = DocumentPaintEncodedBGRA8PlaneInput(
            width: RadialSectorLayout.pageSide,
            height: RadialSectorLayout.pageSide,
            bytesPerRow: RadialSectorLayout.pageSide * 4,
            bytes: Data(
                repeating: 255,
                count: RadialSectorLayout.pageSide
                    * RadialSectorLayout.pageSide * 4
            )
        )

        let request = try DocumentPaintSurfaceEncodedImportRequest.validate(
            layerID: UUID(),
            candidateGeometry: geometry,
            input: .radialPages(selected.map {
                .init(coordinate: $0.coordinate, plane: opaquePage)
            }),
            maximumUploadBytes: 2 * 256 * 256 * 4
        )

        let expectedCoordinates = selected.map {
            PaintTileCoordinate(
                x: $0.atlasSlot % layout.atlasColumns,
                y: $0.atlasSlot / layout.atlasColumns
            )
        }.sorted()
        let expectedBytes = 2 * 256 * 256 * 4
        #expect(request.importDirtyCoordinates == expectedCoordinates)
        #expect(request.importTotalEncodedByteCount == expectedBytes)
    }

    @Test
    func radialRejectsDuplicateOutsideAndNonPageInputs() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 300,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 300, height: 300),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let coordinate = layout.residentPages[0].coordinate
        let page = importPlane(width: 256, height: 256, alpha: 255)

        #expect(throws: DocumentPaintEncodedImportError
            .duplicateRadialPage(coordinate)) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: UUID(), candidateGeometry: geometry,
                input: .radialPages([
                    .init(coordinate: coordinate, plane: page),
                    .init(coordinate: coordinate, plane: page),
                ]),
                maximumUploadBytes: 2 * 256 * 256 * 4
            )
        }
        let outside = RadialPageCoordinate(x: Int.max, y: Int.min)
        #expect(throws: DocumentPaintEncodedImportError
            .radialPageOutsideLayout(outside)) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: UUID(), candidateGeometry: geometry,
                input: .radialPages([
                    .init(coordinate: outside, plane: page),
                ]),
                maximumUploadBytes: 256 * 256 * 4
            )
        }
        #expect(throws: DocumentPaintEncodedImportError.invalidRadialPageSize(
            expected: PixelSize(width: 256, height: 256),
            actual: PixelSize(width: 255, height: 256)
        )) {
            _ = try DocumentPaintSurfaceEncodedImportRequest.validate(
                layerID: UUID(), candidateGeometry: geometry,
                input: .radialPages([
                    .init(
                        coordinate: coordinate,
                        plane: importPlane(width: 255, height: 256, alpha: 255)
                    ),
                ]),
                maximumUploadBytes: 256 * 256 * 4
            )
        }
    }

    @Test
    func transparentRadialPagesAreOmittedAndMissingPagesStayTransparent() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 300,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 300, height: 300),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let request = try DocumentPaintSurfaceEncodedImportRequest.validate(
            layerID: UUID(),
            candidateGeometry: geometry,
            input: .radialPages([
                .init(
                    coordinate: layout.residentPages[0].coordinate,
                    plane: importPlane(width: 256, height: 256, alpha: 0)
                ),
            ]),
            maximumUploadBytes: 0
        )

        #expect(request.importDirtyCoordinates.isEmpty)
        #expect(request.importTotalEncodedByteCount == 0)
    }
}

private func importGeometry(width: Int, height: Int) throws
    -> DocumentPaintGeometry
{
    try DocumentPaintGeometry(
        documentPixelSize: PixelSize(width: width, height: height),
        storagePixelSize: PixelSize(width: width, height: height),
        radialLayout: nil
    )
}

private func importPlane(width: Int, height: Int, alpha: UInt8)
    -> DocumentPaintEncodedBGRA8PlaneInput
{
    var bytes = Data(repeating: 0xAB, count: width * height * 4)
    for offset in stride(from: 3, to: bytes.count, by: 4) {
        bytes[offset] = alpha
    }
    return .init(
        width: width,
        height: height,
        bytesPerRow: width * 4,
        bytes: bytes
    )
}

private func setImportPixel(
    _ bytes: inout Data,
    stride: Int,
    x: Int,
    y: Int,
    bgra: [UInt8]
) {
    let offset = y * stride + x * 4
    bytes.replaceSubrange(offset..<(offset + 4), with: bgra)
}
