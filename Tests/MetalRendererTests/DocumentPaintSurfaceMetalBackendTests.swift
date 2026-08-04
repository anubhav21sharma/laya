import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

private enum DocumentPaintSurfaceMetalBackendTestError: Error {
    case expectedPreparedMutation
    case expectedPreparedImport
}

@Suite("Document paint surface Metal backend", .serialized)
@MainActor
struct DocumentPaintSurfaceMetalBackendTests {
    @Test
    func clearIsTerminalWithoutAllocatingACommandOrResource() throws {
        guard let context = try makeContext() else { return }

        try context.backend.preflight(.clear)
        let token = try context.backend.encode(.clear)
        let encoded = context.backend.debugSnapshot
        #expect(encoded.commandBufferCount == 0)
        #expect(encoded.reductionBufferCount == 0)
        #expect(encoded.importBufferCount == 0)
        #expect(encoded.activeTokenCount == 1)

        #expect(try context.backend.complete(token, as: .succeeded).isEmpty)
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
        #expect(
            throws: DocumentPaintSurfaceMetalBackendError.tokenAlreadyConsumed
        ) {
            _ = try context.backend.complete(token, as: .succeeded)
        }
    }

    @Test
    func emptyResizeAndImportAreValidatedTerminalZeroResourceOperations() throws {
        guard let context = try makeContext() else { return }
        let sourceGeometry = try geometry(width: 256, height: 256)
        let resizedGeometry = try geometry(width: 128, height: 128)
        let resize = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: sourceGeometry,
            candidateGeometry: resizedGeometry,
            clearsDestinationsBeforeCopy: true,
            sources: [],
            destinations: [],
            mappings: []
        ))
        try context.backend.preflight(resize)
        let resizeToken = try context.backend.encode(resize)
        #expect(try context.backend.complete(
            resizeToken,
            as: .succeeded
        ).isEmpty)

        let importGeometry = try geometry(width: 2, height: 2)
        let imported = DocumentPaintSurfaceBackendOperation.encodedImport(.init(
            candidateGeometry: importGeometry,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            encodedPremultipliedBGRA8: Data(repeating: 0, count: 16),
            conversion:
                .encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float,
            clearsDestinationsBeforeConversion: true,
            destinations: [],
            tileRegions: []
        ))
        try context.backend.preflight(imported)
        let importToken = try context.backend.encode(imported)
        #expect(try context.backend.complete(
            importToken,
            as: .succeeded
        ).isEmpty)

        let snapshot = context.backend.debugSnapshot
        #expect(snapshot.commandBufferCount == 0)
        #expect(snapshot.reductionBufferCount == 0)
        #expect(snapshot.importBufferCount == 0)
        #expect(snapshot.encoderCount == 0)
        #expect(snapshot.committedCommandBufferCount == 0)
        #expect(snapshot.activeTokenCount == 0)
    }

    @Test
    func blankPlainToRadialAndRadialToPlainResizeAreTerminal() throws {
        guard let context = try makeContext() else { return }
        let plain = try geometry(width: 64, height: 64)
        let configuration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 4,
            center: WorldPoint(x: 32, y: 32)
        )
        let radial = try radialGeometry(
            configuration: configuration,
            width: 64,
            height: 64
        )
        let plainToRadial = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: plain,
            candidateGeometry: radial,
            targetRadialConfiguration: configuration,
            clearsDestinationsBeforeCopy: true,
            sources: [],
            destinations: [],
            mappings: []
        ))
        try context.backend.preflight(plainToRadial)
        let toRadial = try context.backend.encode(plainToRadial)
        #expect(try context.backend.complete(
            toRadial,
            as: .succeeded
        ).isEmpty)

        let radialToPlain = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: radial,
            candidateGeometry: plain,
            clearsDestinationsBeforeCopy: true,
            sources: [],
            destinations: [],
            mappings: []
        ))
        try context.backend.preflight(radialToPlain)
        let toPlain = try context.backend.encode(radialToPlain)
        #expect(try context.backend.complete(
            toPlain,
            as: .succeeded
        ).isEmpty)
        let mismatchedConfiguration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 3,
            center: WorldPoint(x: 32, y: 32)
        )
        let invalidTarget = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: plain,
            candidateGeometry: radial,
            targetRadialConfiguration: mismatchedConfiguration,
            clearsDestinationsBeforeCopy: true,
            sources: [],
            destinations: [],
            mappings: []
        ))
        #expect(throws: DocumentPaintSurfaceMetalBackendError.invalidOperation) {
            try context.backend.preflight(invalidTarget)
        }
        expectZeroGPUWork(context.backend.debugSnapshot)
    }

    @Test
    func multiTileStrokeUsesOneCommandAndReturnsOrderedStoredAlphaEvidence() throws {
        guard let context = try makeContext() else { return }
        let first = PaintTileCoordinate(x: 0, y: 0)
        let second = PaintTileCoordinate(x: 1, y: 0)
        let firstBounds = try #require(PixelRect(
            minX: 0,
            minY: 0,
            maxX: 256,
            maxY: 256
        ))
        let secondBounds = try #require(PixelRect(
            minX: 256,
            minY: 0,
            maxX: 512,
            maxY: 256
        ))
        let base0 = try texture(context.device)
        let live0 = try texture(context.device)
        let destination0 = try texture(context.device)
        let base1 = try texture(context.device)
        let live1 = try texture(context.device)
        let destination1 = try texture(context.device)
        write(SIMD4(0, 0, 0.5, 0.5), to: base0)
        write(SIMD4(0.4, 0, 0, 0.5), to: live0)
        write(SIMD4(0, 0, 0, 0), to: base1)
        write(SIMD4(0.25, 0, 0, 0.25), to: live1)
        let operation = DocumentPaintSurfaceBackendOperation.stroke(
            DocumentPaintSurfaceStrokeBackendPayload(
                geometry: try geometry(width: 512, height: 256),
                compositeParameters: .init(
                    mode: .draw,
                    strokeOpacity: 0.5,
                    accumulationLimit: 0.25,
                    eraserStrength: 1
                ),
                baseSources: [
                    .texture(.init(
                        coordinate: first,
                        logicalBounds: firstBounds,
                        texture: base0
                    )),
                    .texture(.init(
                        coordinate: second,
                        logicalBounds: secondBounds,
                        texture: base1
                    )),
                ],
                authoritativeSources: [
                    .texture(.init(
                        coordinate: first,
                        logicalBounds: firstBounds,
                        texture: live0
                    )),
                    .texture(.init(
                        coordinate: second,
                        logicalBounds: secondBounds,
                        texture: live1
                    )),
                ],
                destinations: [
                    .init(
                        coordinate: first,
                        logicalBounds: firstBounds,
                        texture: destination0
                    ),
                    .init(
                        coordinate: second,
                        logicalBounds: secondBounds,
                        texture: destination1
                    ),
                ]
            )
        )

        try context.backend.preflight(operation)
        let token = try context.backend.encode(operation)
        #expect(context.backend.debugSnapshot.commandBufferCount == 1)
        #expect(context.backend.debugSnapshot.reductionBufferCount == 1)
        #expect(context.backend.debugSnapshot.activeTokenCount == 1)
        #expect(context.backend.debugSnapshot.activeRetainedTextureCount == 6)
        let evidence = try context.backend.complete(token, as: .succeeded)

        #expect(evidence.map(\.coordinate) == [first, second])
        #expect(evidence.map(\.maximumAlpha) == [
            Float(Float16(0.5625)), Float(Float16(0.125)),
        ])
        #expect(evidence.allSatisfy { !$0.invalid })
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
        #expect(context.backend.debugSnapshot.activeRetainedTextureCount == 0)
    }

    @Test
    func eraseAndKnownClearStrokeMatchCPUReference() throws {
        guard let context = try makeContext() else { return }
        let erase = try strokeOperation(
            context.device,
            base: SIMD4(0.4, 0.2, 0.1, 0.5),
            authoritative: SIMD4(0, 0, 0, 0.25),
            destination: SIMD4(0.9, 0.9, 0.9, 0.9),
            composite: .init(
                mode: .erase,
                strokeOpacity: 1,
                accumulationLimit: 1,
                eraserStrength: 0.5
            )
        )
        let eraseToken = try context.backend.encode(erase.operation)
        let eraseEvidence = try context.backend.complete(
            eraseToken,
            as: .succeeded
        )
        expect(
            read(erase.destination),
            SIMD4(0.35, 0.175, 0.0875, 0.4375)
        )
        #expect(eraseEvidence.map(\.maximumAlpha) == [
            Float(Float16(0.4375)),
        ])

        let bounds = try tileBounds(width: 1, height: 1)
        let clearedDestination = try texture(context.device)
        fill(clearedDestination, with: SIMD4(0.5, 0.5, 0.5, 0.5))
        let knownClear = DocumentPaintSurfaceBackendOperation.stroke(
            .init(
                geometry: try geometry(width: 1, height: 1),
                compositeParameters: .opaqueDraw,
                baseSources: [.knownClear(
                    coordinate: .init(x: 0, y: 0),
                    logicalBounds: bounds
                )],
                authoritativeSources: [.knownClear(
                    coordinate: .init(x: 0, y: 0),
                    logicalBounds: bounds
                )],
                destinations: [.init(
                    coordinate: .init(x: 0, y: 0),
                    logicalBounds: bounds,
                    texture: clearedDestination
                )]
            )
        )
        let clearToken = try context.backend.encode(knownClear)
        let clearEvidence = try context.backend.complete(
            clearToken,
            as: .succeeded
        )
        expect(read(clearedDestination), .zero)
        #expect(clearEvidence.map(\.maximumAlpha) == [0])
    }

    @Test
    func plainResizeClearsThenCopiesOnlyTheMappedRegion() throws {
        guard let context = try makeContext() else { return }
        let resize = try resizeOperation(context.device)
        let token = try context.backend.encode(resize.operation)
        let evidence = try context.backend.complete(token, as: .succeeded)

        expect(read(resize.destination, x: 0, y: 0), .zero)
        expect(
            read(resize.destination, x: 1, y: 1),
            SIMD4(0.1, 0, 0, 0.1)
        )
        expect(
            read(resize.destination, x: 2, y: 2),
            SIMD4(0.4, 0.4, 0, 0.4)
        )
        expect(read(resize.destination, x: 3, y: 2), .zero)
        #expect(evidence.map(\.maximumAlpha) == [Float(Float16(0.4))])
    }

    @Test
    func radialResizeUsesCompilerAuthorityAndMasksOutsideTheTargetOrbit() throws {
        guard let context = try makeContext() else { return }
        let configuration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 4,
            center: WorldPoint(x: 32, y: 32)
        )
        let canvasSize = PixelSize(width: 64, height: 64)
        let compiled = try SymmetryDescriptorCompiler.compile(
            finiteConfiguration: .radial(configuration),
            canvasSize: canvasSize
        )
        let layout = try #require(compiled.domain.finite?.radial.layout)
        let page = try #require(layout.residentPage(
            at: RadialPageCoordinate(x: 0, y: 0)
        ))
        let coordinate = PaintTileCoordinate(
            x: page.atlasSlot % layout.atlasColumns,
            y: page.atlasSlot / layout.atlasColumns
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: canvasSize,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let descriptor = try PaintTileDescriptor(
            coordinate: coordinate,
            logicalPixelSize: layout.atlasPixelSize
        )
        let source = try texture(context.device)
        let destination = try texture(context.device)
        fill(source, with: SIMD4(0.25, 0, 0, 0.25))
        fill(destination, with: SIMD4(0.5, 0.5, 0.5, 0.5))
        let operation = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: geometry,
            candidateGeometry: geometry,
            targetRadialConfiguration: configuration,
            clearsDestinationsBeforeCopy: true,
            sources: [.init(
                coordinate: coordinate,
                logicalBounds: descriptor.logicalBounds,
                texture: source
            )],
            destinations: [.init(
                coordinate: coordinate,
                logicalBounds: descriptor.logicalBounds,
                texture: destination
            )],
            mappings: [.init(
                sourceCoordinate: coordinate,
                destinationCoordinate: coordinate,
                sourceOrigin: .zero,
                destinationOrigin: .zero,
                extent: PixelSize(width: 256, height: 256),
                logicalPage: page.coordinate,
                masksToTargetOrbit: true
            )]
        ))

        let token = try context.backend.encode(operation)
        _ = try context.backend.complete(token, as: .succeeded)
        expect(read(destination, x: 0, y: 0), SIMD4(0.25, 0, 0, 0.25))
        expect(read(destination, x: 255, y: 255), .zero)
    }

    @Test
    func encodedImportHonorsPremultipliedRowsAndPadding() throws {
        guard let context = try makeContext() else { return }
        let imported = try importOperation(context.device)
        let token = try context.backend.encode(imported.operation)
        let encoded = context.backend.debugSnapshot
        #expect(encoded.commandBufferCount == 1)
        #expect(encoded.reductionBufferCount == 1)
        #expect(encoded.importBufferCount == 1)
        #expect(encoded.activeCommandBufferCount == 1)
        #expect(encoded.activeRetainedTextureCount == 1)
        #expect(encoded.activeReductionBufferCount == 1)
        #expect(encoded.activeImportBufferCount == 1)

        let evidence = try context.backend.complete(token, as: .succeeded)
        expect(
            read(imported.destination, x: 0, y: 0),
            SIMD4(0.02554, 0.00721, 0.1075, 0.502),
            tolerance: 0.001
        )
        expect(read(imported.destination, x: 1, y: 0), .zero)
        expect(
            read(imported.destination, x: 0, y: 1),
            SIMD4(0.502, 0, 0, 0.502),
            tolerance: 0.001
        )
        #expect(evidence.map(\.maximumAlpha) == [
            Float(Float16(Float(128) / 255)),
        ])
        #expect(context.backend.debugSnapshot.activeImportBufferCount == 0)
        #expect(context.backend.debugSnapshot.activeRetainedTextureCount == 0)
    }

    @Test
    func restorePreflightIsPureButMetalEncodeRejectsIt() throws {
        guard let context = try makeContext() else { return }
        let bounds = try tileBounds(width: 256, height: 256)
        let restore = DocumentPaintSurfaceBackendOperation.restore(.init(
            reference: RasterRevisionReference(
                id: StoredRasterRevisionID(rawValue: 1),
                pixelSize: PixelSize(width: 256, height: 256),
                regions: PixelRegionSet([], clippedTo: PixelSize(
                    width: 256,
                    height: 256
                )),
                retainedBytes: 0
            ),
            destinations: [.init(
                coordinate: .init(x: 0, y: 0),
                logicalBounds: bounds,
                texture: try texture(context.device)
            )]
        ))

        try context.backend.preflight(restore)
        #expect(context.backend.debugSnapshot.commandBufferCount == 0)
        #expect(throws: DocumentPaintSurfaceMetalBackendError.unsupportedRestore) {
            _ = try context.backend.encode(restore)
        }
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
    }

    @Test
    func tokensRejectForeignAndDuplicateUseWithoutTombstones() throws {
        guard let first = try makeContext(), let second = try makeContext()
        else { return }
        let token = try first.backend.encode(.clear)
        #expect(throws: DocumentPaintSurfaceMetalBackendError.foreignToken) {
            _ = try second.backend.complete(token, as: .succeeded)
        }
        #expect(try first.backend.complete(token, as: .succeeded).isEmpty)
        #expect(
            throws: DocumentPaintSurfaceMetalBackendError.tokenAlreadyConsumed
        ) {
            try first.backend.discardAndWaitUntilTerminal(token)
        }
    }

    @Test(arguments: [
        RasterRevisionOperationOutcome.failed,
        RasterRevisionOperationOutcome.cancelled,
    ])
    func nonSuccessCompletionConsumesTerminalEncoding(
        outcome: RasterRevisionOperationOutcome
    ) throws {
        guard let context = try makeContext() else { return }
        let stroke = try strokeOperation(context.device)
        let token = try context.backend.encode(stroke.operation)
        #expect(try context.backend.complete(token, as: outcome).isEmpty)
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
        #expect(
            throws: DocumentPaintSurfaceMetalBackendError.tokenAlreadyConsumed
        ) {
            _ = try context.backend.complete(token, as: .succeeded)
        }
    }

    @Test(arguments: [
        DocumentPaintSurfaceMetalBackendFailurePoint.metadataAllocation,
        .commandBuffer,
        .reductionBuffer,
        .encoder,
        .precommit,
    ])
    func precommitFailureIsMutationFreeAndImmediatelyRetryable(
        point: DocumentPaintSurfaceMetalBackendFailurePoint
    ) throws {
        let injection = DocumentPaintSurfaceMetalBackendFailureInjection(
            failingOnceAt: point
        )
        guard let context = try makeContext(failureInjection: injection)
        else { return }
        let stroke = try strokeOperation(
            context.device,
            destination: SIMD4(0.2, 0.1, 0.05, 0.25)
        )
        let expectedError: DocumentPaintSurfaceMetalBackendError = switch point {
        case .metadataAllocation: .metadataAllocationFailed
        case .commandBuffer: .commandBufferUnavailable
        case .reductionBuffer: .reductionBufferAllocationFailed
        case .encoder: .encoderUnavailable
        case .precommit: .precommitFailed
        default: fatalError("Unexpected precommit failure point")
        }

        #expect(throws: expectedError) {
            _ = try context.backend.encode(stroke.operation)
        }
        expect(
            read(stroke.destination),
            SIMD4(0.2, 0.1, 0.05, 0.25)
        )
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
        #expect(context.backend.debugSnapshot.committedCommandBufferCount == 0)

        let retry = try context.backend.encode(stroke.operation)
        _ = try context.backend.complete(retry, as: .succeeded)
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
    }

    @Test
    func importAllocationFailureIsMutationFreeAndRetryable() throws {
        let injection = DocumentPaintSurfaceMetalBackendFailureInjection(
            failingOnceAt: .importBuffer
        )
        guard let context = try makeContext(failureInjection: injection)
        else { return }
        let imported = try importOperation(context.device)
        #expect(
            throws: DocumentPaintSurfaceMetalBackendError
                .importBufferAllocationFailed
        ) {
            _ = try context.backend.encode(imported.operation)
        }
        expect(
            read(imported.destination),
            SIMD4(0.2, 0.2, 0.2, 0.2)
        )
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
        let retry = try context.backend.encode(imported.operation)
        _ = try context.backend.complete(retry, as: .succeeded)
    }

    @Test
    func gpuAndTerminalFailuresPreserveTokensForRetryOrDiscard() throws {
        let gpuInjection = DocumentPaintSurfaceMetalBackendFailureInjection(
            failingOnceAt: .gpu
        )
        guard let gpu = try makeContext(failureInjection: gpuInjection)
        else { return }
        let gpuStroke = try strokeOperation(gpu.device)
        let gpuToken = try gpu.backend.encode(gpuStroke.operation)
        #expect(throws: DocumentPaintSurfaceMetalBackendError.gpuCommandFailed) {
            _ = try gpu.backend.complete(gpuToken, as: .succeeded)
        }
        #expect(gpu.backend.debugSnapshot.activeTokenCount == 1)
        try gpu.backend.discardAndWaitUntilTerminal(gpuToken)
        #expect(gpu.backend.debugSnapshot.activeTokenCount == 0)

        let completionInjection =
            DocumentPaintSurfaceMetalBackendFailureInjection(
                failingOnceAt: .complete
            )
        guard let completion = try makeContext(
            failureInjection: completionInjection
        ) else { return }
        let completionStroke = try strokeOperation(completion.device)
        let completionToken = try completion.backend.encode(
            completionStroke.operation
        )
        #expect(throws: DocumentPaintSurfaceMetalBackendError.completionFailed) {
            _ = try completion.backend.complete(
                completionToken,
                as: .succeeded
            )
        }
        #expect(completion.backend.debugSnapshot.activeTokenCount == 1)
        _ = try completion.backend.complete(completionToken, as: .succeeded)
        #expect(completion.backend.debugSnapshot.activeTokenCount == 0)

        let discardInjection =
            DocumentPaintSurfaceMetalBackendFailureInjection(
                failingOnceAt: .discard
            )
        guard let discard = try makeContext(
            failureInjection: discardInjection
        ) else { return }
        let discardStroke = try strokeOperation(discard.device)
        let discardToken = try discard.backend.encode(discardStroke.operation)
        #expect(throws: DocumentPaintSurfaceMetalBackendError.discardFailed) {
            try discard.backend.discardAndWaitUntilTerminal(discardToken)
        }
        #expect(discard.backend.debugSnapshot.activeTokenCount == 1)
        try discard.backend.discardAndWaitUntilTerminal(discardToken)
        #expect(discard.backend.debugSnapshot.activeTokenCount == 0)
    }

    @Test(arguments: [
        DocumentPaintSurfaceMetalBackendFailurePoint.metadataAllocation,
        .commandBuffer,
        .reductionBuffer,
        .importBuffer,
        .encoder,
        .precommit,
        .gpu,
        .complete,
        .discard,
    ])
    func clearBypassesAllGPUFailureSeams(
        point: DocumentPaintSurfaceMetalBackendFailurePoint
    ) throws {
        let injection = DocumentPaintSurfaceMetalBackendFailureInjection(
            failingOnceAt: point
        )
        guard let context = try makeContext(failureInjection: injection)
        else { return }
        let token = try context.backend.encode(.clear)
        #expect(try context.backend.complete(token, as: .succeeded).isEmpty)
        let snapshot = context.backend.debugSnapshot
        #expect(snapshot.commandBufferCount == 0)
        #expect(snapshot.reductionBufferCount == 0)
        #expect(snapshot.importBufferCount == 0)
        #expect(snapshot.activeTokenCount == 0)
    }

    @Test(arguments: [
        DocumentPaintSurfaceMetalBackendFailurePoint.metadataAllocation,
        .commandBuffer,
        .reductionBuffer,
        .importBuffer,
        .encoder,
        .precommit,
        .gpu,
        .complete,
        .discard,
    ])
    func emptyResizeAndImportBypassAllGPUFailureSeams(
        point: DocumentPaintSurfaceMetalBackendFailurePoint
    ) throws {
        let injection = DocumentPaintSurfaceMetalBackendFailureInjection(
            failingOnceAt: point
        )
        guard let context = try makeContext(failureInjection: injection)
        else { return }
        let sourceGeometry = try geometry(width: 256, height: 256)
        let targetGeometry = try geometry(width: 128, height: 128)
        let resize = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: sourceGeometry,
            candidateGeometry: targetGeometry,
            clearsDestinationsBeforeCopy: true,
            sources: [],
            destinations: [],
            mappings: []
        ))
        let resizeToken = try context.backend.encode(resize)
        #expect(try context.backend.complete(
            resizeToken,
            as: .succeeded
        ).isEmpty)

        let imported = DocumentPaintSurfaceBackendOperation.encodedImport(.init(
            candidateGeometry: targetGeometry,
            width: 128,
            height: 128,
            bytesPerRow: 512,
            encodedPremultipliedBGRA8: Data(repeating: 0, count: 65_536),
            conversion:
                .encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float,
            clearsDestinationsBeforeConversion: true,
            destinations: [],
            tileRegions: []
        ))
        let importToken = try context.backend.encode(imported)
        if point == .discard {
            try context.backend.discardAndWaitUntilTerminal(importToken)
        } else {
            #expect(try context.backend.complete(
                importToken,
                as: .succeeded
            ).isEmpty)
        }
        expectZeroGPUWork(context.backend.debugSnapshot)
    }

    @Test
    func transactionIntegratesMetalBackendForStrokeClearResizeAndImport() throws {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)

        guard let stroke = try makeTransactionFixture(width: 1, height: 1)
        else { return }
        _ = try commit(
            stroke,
            request: .init(
                kind: .stroke,
                layerID: stroke.layerID,
                baseGeometry: stroke.geometry,
                candidateGeometry: stroke.geometry,
                dirtyCoordinates: [coordinate],
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: false
            )
        )
        #expect(stroke.backend.debugSnapshot.commandBufferCount == 1)
        #expect(stroke.backend.debugSnapshot.activeTokenCount == 0)
        #expect(stroke.registry.snapshot().layers[0].references.isEmpty)

        guard let clear = try makeTransactionFixture(width: 256, height: 256)
        else { return }
        try seed(clear, coordinate: coordinate, pixel: SIMD4(0.25, 0, 0, 0.25))
        _ = try commit(
            clear,
            request: .init(
                kind: .clear,
                layerID: clear.layerID,
                baseGeometry: clear.geometry,
                candidateGeometry: clear.geometry,
                dirtyCoordinates: [],
                explicitlyRemovedCoordinates: [coordinate],
                requiresHistoryPair: false
            )
        )
        #expect(clear.backend.debugSnapshot.commandBufferCount == 0)
        #expect(clear.registry.snapshot().layers[0].references.isEmpty)

        guard let resize = try makeTransactionFixture(width: 256, height: 256)
        else { return }
        try seed(
            resize,
            coordinate: coordinate,
            pixel: SIMD4(0.25, 0, 0, 0.25)
        )
        let resizedGeometry = try geometry(width: 128, height: 128)
        _ = try commit(
            resize,
            request: .init(
                kind: .resize,
                layerID: resize.layerID,
                baseGeometry: resize.geometry,
                candidateGeometry: resizedGeometry,
                dirtyCoordinates: [coordinate],
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: false
            )
        )
        #expect(resize.backend.debugSnapshot.commandBufferCount == 1)
        #expect(resize.registry.snapshot().geometry == resizedGeometry)
        #expect(resize.registry.snapshot().layers[0].references.map(\.coordinate)
            == [coordinate])

        guard let imported = try makeTransactionFixture(width: 2, height: 2)
        else { return }
        let importRequest = DocumentPaintSurfaceEncodedImportRequest(
            layerID: imported.layerID,
            candidateGeometry: imported.geometry,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            encodedPremultipliedBGRA8: Data([
                0, 0, 128, 128, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
            ])
        )
        _ = try commit(imported, request: importRequest)
        #expect(imported.backend.debugSnapshot.commandBufferCount == 1)
        #expect(imported.backend.debugSnapshot.importBufferCount == 1)
        #expect(imported.registry.snapshot().layers[0].references.map(\.coordinate)
            == [coordinate])
    }

    @Test
    func transactionPublishesBlankResizeAndTransparentImportWithZeroGPUWork() throws {
        guard let resize = try makeTransactionFixture(width: 256, height: 256)
        else { return }
        let resizedGeometry = try geometry(width: 128, height: 128)
        _ = try commit(
            resize,
            request: .init(
                kind: .resize,
                layerID: resize.layerID,
                baseGeometry: resize.geometry,
                candidateGeometry: resizedGeometry,
                dirtyCoordinates: [],
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: false
            )
        )
        #expect(resize.registry.snapshot().geometry == resizedGeometry)
        #expect(resize.registry.snapshot().layers[0].references.isEmpty)
        expectZeroGPUWork(resize.backend.debugSnapshot)

        guard let imported = try makeTransactionFixture(width: 2, height: 2)
        else { return }
        let importedGeometry = try geometry(width: 3, height: 2)
        _ = try commit(
            imported,
            request: .init(
                layerID: imported.layerID,
                candidateGeometry: importedGeometry,
                width: 3,
                height: 2,
                bytesPerRow: 12,
                encodedPremultipliedBGRA8: Data(repeating: 0, count: 24)
            )
        )
        #expect(imported.registry.snapshot().geometry == importedGeometry)
        #expect(imported.registry.snapshot().layers[0].references.isEmpty)
        expectZeroGPUWork(imported.backend.debugSnapshot)
    }

    @Test
    func transactionPublishesBlankPlainRadialModeSwitchesWithZeroGPUWork() throws {
        let plainGeometry = try geometry(width: 64, height: 64)
        let configuration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 4,
            center: WorldPoint(x: 32, y: 32)
        )
        let radialGeometry = try radialGeometry(
            configuration: configuration,
            width: 64,
            height: 64
        )

        guard let plain = try makeTransactionFixture(
            geometry: plainGeometry
        ) else { return }
        _ = try commit(
            plain,
            request: .init(
                kind: .resize,
                layerID: plain.layerID,
                baseGeometry: plainGeometry,
                candidateGeometry: radialGeometry,
                targetRadialConfiguration: configuration,
                dirtyCoordinates: [],
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: false
            )
        )
        #expect(plain.registry.snapshot().geometry == radialGeometry)
        #expect(plain.registry.snapshot().layers[0].references.isEmpty)
        expectZeroGPUWork(plain.backend.debugSnapshot)

        guard let radial = try makeTransactionFixture(
            geometry: radialGeometry
        ) else { return }
        _ = try commit(
            radial,
            request: .init(
                kind: .resize,
                layerID: radial.layerID,
                baseGeometry: radialGeometry,
                candidateGeometry: plainGeometry,
                dirtyCoordinates: [],
                explicitlyRemovedCoordinates: [],
                requiresHistoryPair: false
            )
        )
        #expect(radial.registry.snapshot().geometry == plainGeometry)
        #expect(radial.registry.snapshot().layers[0].references.isEmpty)
        expectZeroGPUWork(radial.backend.debugSnapshot)

        guard let nonempty = try makeTransactionFixture(
            geometry: plainGeometry
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try seed(
            nonempty,
            coordinate: coordinate,
            pixel: SIMD4(0.25, 0, 0, 0.25)
        )
        #expect(
            throws: DocumentPaintSurfaceTransactionError.invalidResizeMapping
        ) {
            _ = try nonempty.coordinator.prepareMutation(.init(
                kind: .resize,
                layerID: nonempty.layerID,
                baseGeometry: plainGeometry,
                candidateGeometry: radialGeometry,
                targetRadialConfiguration: configuration,
                dirtyCoordinates: [],
                explicitlyRemovedCoordinates: [coordinate],
                requiresHistoryPair: false
            ))
        }
        #expect(nonempty.registry.snapshot().geometry == plainGeometry)
        #expect(nonempty.registry.snapshot().layers[0].references.map(\.coordinate)
            == [coordinate])
        expectZeroGPUWork(nonempty.backend.debugSnapshot)
    }

    @Test
    func invalidPreflightAndInjectedGPUFailureNeverPublishCandidates() throws {
        guard let context = try makeContext() else { return }
        let stroke = try strokeOperation(context.device)
        guard case let .stroke(payload) = stroke.operation else {
            Issue.record("Expected stroke operation")
            return
        }
        let aliased = DocumentPaintSurfaceBackendOperation.stroke(.init(
            geometry: payload.geometry,
            compositeParameters: payload.compositeParameters,
            baseSources: payload.baseSources,
            authoritativeSources: payload.authoritativeSources,
            destinations: [.init(
                coordinate: payload.destinations[0].coordinate,
                logicalBounds: payload.destinations[0].logicalBounds,
                texture: {
                    guard case let .texture(source) = payload.baseSources[0]
                    else { preconditionFailure("Expected texture source") }
                    return source.texture
                }()
            )]
        ))
        #expect(throws: DocumentPaintSurfaceMetalBackendError.textureAlias) {
            try context.backend.preflight(aliased)
        }
        let pure = context.backend.debugSnapshot
        #expect(pure.commandBufferCount == 0)
        #expect(pure.reductionBufferCount == 0)
        #expect(pure.importBufferCount == 0)
        #expect(pure.encoderCount == 0)
        #expect(pure.committedCommandBufferCount == 0)
        #expect(pure.activeTokenCount == 0)

        let injection = DocumentPaintSurfaceMetalBackendFailureInjection(
            failingOnceAt: .gpu
        )
        guard let transaction = try makeTransactionFixture(
            width: 1,
            height: 1,
            failureInjection: injection
        ) else { return }
        let baseline = transaction.registry.snapshot()
        let request = DocumentPaintSurfaceMutationRequest(
            kind: .stroke,
            layerID: transaction.layerID,
            baseGeometry: transaction.geometry,
            candidateGeometry: transaction.geometry,
            dirtyCoordinates: [.init(x: 0, y: 0)],
            explicitlyRemovedCoordinates: [],
            requiresHistoryPair: false
        )
        guard case let .prepared(prepared) = try transaction.coordinator
            .prepareMutation(request)
        else {
            Issue.record("Expected prepared mutation")
            return
        }
        let encoded = try transaction.coordinator.encodeMutation(prepared)
        #expect(
            throws: DocumentPaintSurfaceTransactionError
                .backendCompletionFailed
        ) {
            _ = try transaction.coordinator.completeMutation(
                encoded,
                as: .succeeded
            )
        }
        #expect(transaction.registry.snapshot() == baseline)
        #expect(transaction.backend.debugSnapshot.activeTokenCount == 0)
        #expect(transaction.coordinator.snapshot().state == .idle)
    }

    @Test
    func malformedDuplicatePayloadsFailCheckedPreflightWithoutTrapping() throws {
        guard let context = try makeContext() else { return }
        let resize = try resizeOperation(context.device)
        guard case let .resize(resizePayload) = resize.operation else {
            Issue.record("Expected resize operation")
            return
        }
        let duplicateResize = DocumentPaintSurfaceBackendOperation.resize(.init(
            sourceGeometry: resizePayload.sourceGeometry,
            candidateGeometry: resizePayload.candidateGeometry,
            clearsDestinationsBeforeCopy: true,
            sources: resizePayload.sources + resizePayload.sources,
            destinations: resizePayload.destinations
                + resizePayload.destinations,
            mappings: resizePayload.mappings + resizePayload.mappings
        ))
        #expect(throws: DocumentPaintSurfaceMetalBackendError.invalidOperation) {
            try context.backend.preflight(duplicateResize)
        }

        let imported = try importOperation(context.device)
        guard case let .encodedImport(importPayload) = imported.operation else {
            Issue.record("Expected import operation")
            return
        }
        let duplicateImport = DocumentPaintSurfaceBackendOperation
            .encodedImport(.init(
                candidateGeometry: importPayload.candidateGeometry,
                width: importPayload.width,
                height: importPayload.height,
                bytesPerRow: importPayload.bytesPerRow,
                encodedPremultipliedBGRA8:
                    importPayload.encodedPremultipliedBGRA8,
                conversion: importPayload.conversion,
                clearsDestinationsBeforeConversion: true,
                destinations: importPayload.destinations
                    + importPayload.destinations,
                tileRegions: importPayload.tileRegions
                    + importPayload.tileRegions
            ))
        #expect(throws: DocumentPaintSurfaceMetalBackendError.invalidOperation) {
            try context.backend.preflight(duplicateImport)
        }
        #expect(context.backend.debugSnapshot.commandBufferCount == 0)
        #expect(context.backend.debugSnapshot.activeTokenCount == 0)
    }

    @Test
    func emptyImportRejectsSourceBytesContainingVisiblePixels() throws {
        guard let context = try makeContext() else { return }
        var bytes = Data(repeating: 0, count: 16)
        bytes[3] = 255
        let malformed = DocumentPaintSurfaceBackendOperation.encodedImport(.init(
            candidateGeometry: try geometry(width: 2, height: 2),
            width: 2,
            height: 2,
            bytesPerRow: 8,
            encodedPremultipliedBGRA8: bytes,
            conversion:
                .encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float,
            clearsDestinationsBeforeConversion: true,
            destinations: [],
            tileRegions: []
        ))
        #expect(throws: DocumentPaintSurfaceMetalBackendError.invalidOperation) {
            try context.backend.preflight(malformed)
        }
        expectZeroGPUWork(context.backend.debugSnapshot)
    }

    private func makeContext() throws -> (
        device: any MTLDevice,
        backend: DocumentPaintSurfaceMetalBackend
    )? {
        try makeContext(failureInjection: nil)
    }

    private func makeContext(
        failureInjection: DocumentPaintSurfaceMetalBackendFailureInjection?
    ) throws -> (
        device: any MTLDevice,
        backend: DocumentPaintSurfaceMetalBackend
    )? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let library = try makeShaderLibrary(device: device)
        let pipelines = try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
            device: device,
            library: library
        )
        return (
            device,
            try DocumentPaintSurfaceMetalBackend(
                device: device,
                commandQueue: queue,
                pipelines: pipelines,
                failureInjection: failureInjection
            )
        )
    }

    private func expectZeroGPUWork(
        _ snapshot: DocumentPaintSurfaceMetalBackendDebugSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.commandBufferCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.reductionBufferCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.importBufferCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.encoderCount == 0, sourceLocation: sourceLocation)
        #expect(
            snapshot.committedCommandBufferCount == 0,
            sourceLocation: sourceLocation
        )
        #expect(snapshot.activeTokenCount == 0, sourceLocation: sourceLocation)
        #expect(
            snapshot.activeRetainedTextureCount == 0,
            sourceLocation: sourceLocation
        )
    }

    private struct MetalTransactionFixture {
        let device: any MTLDevice
        let queue: any MTLCommandQueue
        let layerID: UUID
        let geometry: DocumentPaintGeometry
        let registry: DocumentPaintSurfaceStore
        let revisions: TiledRasterRevisionStore
        let backend: DocumentPaintSurfaceMetalBackend
        let coordinator: DocumentPaintSurfaceTransaction
    }

    private func makeTransactionFixture(
        width: Int,
        height: Int,
        failureInjection:
            DocumentPaintSurfaceMetalBackendFailureInjection? = nil
    ) throws -> MetalTransactionFixture? {
        try makeTransactionFixture(
            geometry: geometry(width: width, height: height),
            failureInjection: failureInjection
        )
    }

    private func makeTransactionFixture(
        geometry: DocumentPaintGeometry,
        failureInjection:
            DocumentPaintSurfaceMetalBackendFailureInjection? = nil
    ) throws -> MetalTransactionFixture? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let layerID = UUID()
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            geometry: geometry,
            layerIDs: [layerID]
        )
        let revisions = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 16
        )
        let pipelines = try DocumentPaintSurfaceMutationPipelineLibrary.prepare(
            device: device,
            library: makeShaderLibrary(device: device)
        )
        let backend = try DocumentPaintSurfaceMetalBackend(
            device: device,
            commandQueue: queue,
            pipelines: pipelines,
            failureInjection: failureInjection
        )
        let coordinator = DocumentPaintSurfaceTransaction(
            registry: registry,
            revisionStore: revisions,
            commandQueue: queue,
            mutationBackend: backend,
            allowKnownClearAuthoritativeStrokeSourcesForTesting: true
        )
        return MetalTransactionFixture(
            device: device,
            queue: queue,
            layerID: layerID,
            geometry: geometry,
            registry: registry,
            revisions: revisions,
            backend: backend,
            coordinator: coordinator
        )
    }

    private func commit(
        _ fixture: MetalTransactionFixture,
        request: DocumentPaintSurfaceMutationRequest
    ) throws -> DocumentPaintSurfaceCommitResult {
        guard case let .prepared(prepared) = try fixture.coordinator
            .prepareMutation(request)
        else {
            throw DocumentPaintSurfaceMetalBackendTestError
                .expectedPreparedMutation
        }
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
        return try fixture.coordinator.publish(terminal)
    }

    private func commit(
        _ fixture: MetalTransactionFixture,
        request: DocumentPaintSurfaceEncodedImportRequest
    ) throws -> DocumentPaintSurfaceCommitResult {
        guard case let .prepared(prepared) = try fixture.coordinator
            .prepareEncodedImport(request)
        else {
            throw DocumentPaintSurfaceMetalBackendTestError
                .expectedPreparedImport
        }
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
        return try fixture.coordinator.publish(terminal)
    }

    private func seed(
        _ fixture: MetalTransactionFixture,
        coordinate: PaintTileCoordinate,
        pixel: SIMD4<Float16>
    ) throws {
        let candidate = try fixture.registry.makeCandidate(
            dirtyCoordinatesByLayer: [fixture.layerID: [coordinate]]
        )
        fixture.registry.commitPrepared(
            try fixture.registry.prepareCommit(candidate)
        )
        let binding = try fixture.registry.binding(for: fixture.layerID)
        let lease = try binding.canonical.leaseExistingTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        defer { try? binding.canonical.returnLease(lease) }
        let destination = try #require(lease.bindings.first?.texture)
        let pixels = Array(
            repeating: pixel,
            count: PaintTileDescriptor.side * PaintTileDescriptor.side
        )
        let staging = try pixels.withUnsafeBytes { bytes in
            try #require(fixture.device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
        let command = try #require(fixture.queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        let bytesPerRow = PaintTileDescriptor.side
            * MemoryLayout<SIMD4<Float16>>.stride
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * PaintTileDescriptor.side,
            sourceSize: MTLSize(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
                depth: 1
            ),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
    }

    private func strokeOperation(
        _ device: any MTLDevice,
        base: SIMD4<Float16> = SIMD4(0, 0, 0.5, 0.5),
        authoritative: SIMD4<Float16> = SIMD4(0.4, 0, 0, 0.5),
        destination initialDestination: SIMD4<Float16> = .zero,
        composite: DocumentPaintStrokeCompositeParameters = .init(
            mode: .draw,
            strokeOpacity: 0.5,
            accumulationLimit: 0.25,
            eraserStrength: 1
        )
    ) throws -> (
        operation: DocumentPaintSurfaceBackendOperation,
        destination: any MTLTexture
    ) {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let bounds = try tileBounds(width: 1, height: 1)
        let baseTexture = try texture(device)
        let authoritativeTexture = try texture(device)
        let destination = try texture(device)
        fill(baseTexture, with: .zero)
        fill(authoritativeTexture, with: .zero)
        fill(destination, with: initialDestination)
        write(base, to: baseTexture)
        write(authoritative, to: authoritativeTexture)
        return (
            .stroke(.init(
                geometry: try geometry(width: 1, height: 1),
                compositeParameters: composite,
                baseSources: [.texture(.init(
                    coordinate: coordinate,
                    logicalBounds: bounds,
                    texture: baseTexture
                ))],
                authoritativeSources: [.texture(.init(
                    coordinate: coordinate,
                    logicalBounds: bounds,
                    texture: authoritativeTexture
                ))],
                destinations: [.init(
                    coordinate: coordinate,
                    logicalBounds: bounds,
                    texture: destination
                )]
            )),
            destination
        )
    }

    private func resizeOperation(
        _ device: any MTLDevice
    ) throws -> (
        operation: DocumentPaintSurfaceBackendOperation,
        destination: any MTLTexture
    ) {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let bounds = try tileBounds(width: 3, height: 3)
        let source = try texture(device)
        let destination = try texture(device)
        fill(source, with: .zero)
        fill(destination, with: SIMD4(0.2, 0.2, 0.2, 0.2))
        write([
            SIMD4<Float16>(0.1, 0, 0, 0.1),
            SIMD4<Float16>(0, 0.2, 0, 0.2),
            SIMD4<Float16>(0, 0, 0.3, 0.3),
            SIMD4<Float16>(0.4, 0.4, 0, 0.4),
        ], width: 2, height: 2, to: source)
        let geometry = try geometry(width: 3, height: 3)
        return (
            .resize(.init(
                sourceGeometry: geometry,
                candidateGeometry: geometry,
                clearsDestinationsBeforeCopy: true,
                sources: [.init(
                    coordinate: coordinate,
                    logicalBounds: bounds,
                    texture: source
                )],
                destinations: [.init(
                    coordinate: coordinate,
                    logicalBounds: bounds,
                    texture: destination
                )],
                mappings: [.init(
                    sourceCoordinate: coordinate,
                    destinationCoordinate: coordinate,
                    sourceOrigin: .zero,
                    destinationOrigin: SIMD2(1, 1),
                    extent: PixelSize(width: 2, height: 2),
                    logicalPage: nil,
                    masksToTargetOrbit: false
                )]
            )),
            destination
        )
    }

    private func importOperation(
        _ device: any MTLDevice
    ) throws -> (
        operation: DocumentPaintSurfaceBackendOperation,
        destination: any MTLTexture
    ) {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let bounds = try tileBounds(width: 2, height: 2)
        let destination = try texture(device)
        fill(destination, with: SIMD4(0.2, 0.2, 0.2, 0.2))
        let bytes: [UInt8] = [
            64, 16, 32, 128, 9, 8, 7, 0, 0xAA, 0xBB, 0xCC, 0xDD,
            0, 0, 128, 128, 0, 0, 0, 0, 0xEE, 0xFF, 0x11, 0x22,
        ]
        return (
            .encodedImport(.init(
                candidateGeometry: try geometry(width: 2, height: 2),
                width: 2,
                height: 2,
                bytesPerRow: 12,
                encodedPremultipliedBGRA8: Data(bytes),
                conversion:
                    .encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float,
                clearsDestinationsBeforeConversion: true,
                destinations: [.init(
                    coordinate: coordinate,
                    logicalBounds: bounds,
                    texture: destination
                )],
                tileRegions: [.init(
                    coordinate: coordinate,
                    sourceOrigin: .zero,
                    sourceByteOffset: 0,
                    destinationOrigin: .zero,
                    extent: PixelSize(width: 2, height: 2)
                )]
            )),
            destination
        )
    }

    private func tileBounds(width: Int, height: Int) throws -> PixelRect {
        try #require(PixelRect(
            minX: 0,
            minY: 0,
            maxX: width,
            maxY: height
        ))
    }

    private func geometry(width: Int, height: Int) throws
        -> DocumentPaintGeometry
    {
        let size = PixelSize(width: width, height: height)
        return try DocumentPaintGeometry(
            documentPixelSize: size,
            storagePixelSize: size,
            radialLayout: nil
        )
    }

    private func radialGeometry(
        configuration: RadialSymmetryConfiguration,
        width: Int,
        height: Int
    ) throws -> DocumentPaintGeometry {
        let documentSize = PixelSize(width: width, height: height)
        let compiled = try SymmetryDescriptorCompiler.compile(
            finiteConfiguration: .radial(configuration),
            canvasSize: documentSize
        )
        let layout = try #require(compiled.domain.finite?.radial.layout)
        return try DocumentPaintGeometry(
            documentPixelSize: documentSize,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
    }

    private func texture(_ device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 256,
            height: 256,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func write(
        _ pixel: SIMD4<Float16>,
        to texture: any MTLTexture
    ) {
        var pixel = pixel
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: MemoryLayout<SIMD4<Float16>>.stride
        )
    }

    private func write(
        _ pixels: [SIMD4<Float16>],
        width: Int,
        height: Int,
        to texture: any MTLTexture
    ) {
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * MemoryLayout<SIMD4<Float16>>.stride
            )
        }
    }

    private func fill(
        _ texture: any MTLTexture,
        with pixel: SIMD4<Float16>
    ) {
        let pixels = Array(
            repeating: pixel,
            count: texture.width * texture.height
        )
        write(
            pixels,
            width: texture.width,
            height: texture.height,
            to: texture
        )
    }

    private func read(
        _ texture: any MTLTexture,
        x: Int = 0,
        y: Int = 0
    ) -> SIMD4<Float> {
        var pixel = SIMD4<Float16>.zero
        texture.getBytes(
            &pixel,
            bytesPerRow: MemoryLayout<SIMD4<Float16>>.stride,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return SIMD4(
            Float(pixel.x),
            Float(pixel.y),
            Float(pixel.z),
            Float(pixel.w)
        )
    }

    private func expect(
        _ actual: SIMD4<Float>,
        _ expected: SIMD4<Float>,
        tolerance: Float = 0.0005,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual.x - expected.x) <= tolerance
                && abs(actual.y - expected.y) <= tolerance
                && abs(actual.z - expected.z) <= tolerance
                && abs(actual.w - expected.w) <= tolerance,
            "actual: \(actual), expected: \(expected)",
            sourceLocation: sourceLocation
        )
    }

    private func makeShaderLibrary(device: any MTLDevice) throws -> any MTLLibrary {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let shader = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            encoding: .utf8
        )
        return try device.makeLibrary(
            source: shader.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
    }
}
